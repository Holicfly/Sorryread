import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'reader_source.dart';

class ReadingFont {
  const ReadingFont(this.id, this.label, this.detail, this.asset, this.sha);
  final String id, label, detail, asset, sha;
}

const readingFonts = [
  ReadingFont('system', '系统字体', '跟随手机默认字体', '', ''),
  ReadingFont(
    'song',
    '宋体',
    '思源宋体 · 已内置',
    'assets/fonts/song.otf',
    '78aa7a328fd974df2d688c8a9fd74a33d8334dfa84ab24d9d11efb2ffc464117',
  ),
  ReadingFont(
    'hei',
    '黑体',
    'Noto Sans CJK SC · 已内置',
    'assets/fonts/hei.otf',
    '2c76254f6fc379fddfce0a7e84fb5385bb135d3e399294f6eeb6680d0365b74b',
  ),
  ReadingFont(
    'kai',
    '楷体',
    '霞鹜臻楷 · 已内置',
    'assets/fonts/kai.ttf',
    'bf4ea8c39b51784469020120125715d3075137233fe337b5d0a7327f9dfc03bd',
  ),
  ReadingFont(
    'sourceHan',
    '思源黑体',
    'Adobe Source Han Sans SC · 已内置',
    'assets/fonts/sourceHan.otf',
    'f1d8611151880c6c336aabeac4640ef434fa13cbfbf1ffe82d0a71b2a5637256',
  ),
  ReadingFont(
    'wenkai',
    '霞鹜文楷',
    'LXGW WenKai · 已内置',
    'assets/fonts/wenkai.ttf',
    '2d73eea94ad808999d90c0000c239a84a33b09d4bc6ab6c5b8bbf1eda8a7fc8b',
  ),
];

class ReaderFonts {
  ReaderFonts() {
    if (!_licensesRegistered) {
      _licensesRegistered = true;
      LicenseRegistry.addLicense(() async* {
        for (final name in [
          'SourceHanSerif',
          'SourceHanSans',
          'NotoSans',
          'LXGWWenKai',
          'LXGWZhenKai',
        ]) {
          yield LicenseEntryWithLineBreaks([
            name,
          ], await rootBundle.loadString('assets/font_licenses/$name.txt'));
        }
      });
    }
  }
  static bool _licensesRegistered = false;
  static final _loading = <String, Future<void>>{};
  String label(String id) =>
      readingFonts.where((f) => f.id == id).firstOrNull?.label ?? '系统字体';

  // Assets are verified in the packaging test. Load only the chosen face and
  // retain its registration; no disk cache, download, or UI-isolate hashing.
  Future<String?> load(String id) async {
    if (id == 'system') return null;
    final font = readingFonts.where((f) => f.id == id).firstOrNull;
    if (font == null) throw const ReaderFailure('未找到字体。');
    final family = 'ReaderFont${font.sha}';
    try {
      await (_loading[family] ??= _register(family, font.asset));
    } catch (_) {
      _loading.remove(family);
      rethrow;
    }
    return family;
  }

  Future<void> _register(String family, String asset) async {
    final loader = FontLoader(family)..addFont(rootBundle.load(asset));
    await loader.load();
  }
}
