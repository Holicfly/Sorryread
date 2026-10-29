import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import 'reader_fonts.dart';

// Font speculation must not create/dispose a search page's reader repository.
final readerFontWarmupProvider = Provider<Future<void> Function()>((ref) {
  return () async {
    final support = await getApplicationSupportDirectory();
    await warmStoredReaderFont(Directory('${support.path}/reading'));
  };
});

Future<void> warmStoredReaderFont(Directory directory) async {
  final data = jsonDecode(
    await File('${directory.path}/preferences.json').readAsString(),
  );
  if (data is Map && data['font'] is String) {
    await ReaderFonts().load(data['font'] as String);
  }
}
