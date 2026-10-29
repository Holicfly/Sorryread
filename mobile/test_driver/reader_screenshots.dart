import 'dart:io';
import 'dart:convert';

import 'package:integration_test/integration_test_driver_extended.dart';

Future<void> main() async {
  final output = Directory(
    Platform.environment['READER_CAPTURE_DIR'] ?? '../artifacts/reader-phone',
  );
  await output.create(recursive: true);
  await integrationDriver(
    responseDataCallback: (data) async {
      if (data != null) {
        final summary = Map<String, dynamic>.from(data)..remove('screenshots');
        await File('${output.path}/result.json')
            .writeAsString(jsonEncode(summary));
      }
    },
    onScreenshot: (name, bytes, [args]) async {
      if (!RegExp(r'^[a-z-]+$').hasMatch(name)) return false;
      await File('${output.path}/$name.png').writeAsBytes(bytes);
      return bytes.isNotEmpty;
    },
  );
}
