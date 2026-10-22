import 'dart:io';

import 'package:integration_test/integration_test_driver_extended.dart';

Future<void> main() async {
  final output = Directory('../artifacts/mobile-framework');
  await output.create(recursive: true);
  await integrationDriver(
    responseDataCallback: null,
    onScreenshot: (name, bytes, [args]) async {
      if (!RegExp(r'^[a-z-]+$').hasMatch(name)) return false;
      await File('${output.path}/$name.png').writeAsBytes(bytes);
      return bytes.isNotEmpty;
    },
  );
}
