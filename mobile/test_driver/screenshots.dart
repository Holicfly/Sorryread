import 'dart:io';
import 'dart:convert';

import 'package:integration_test/integration_test_driver_extended.dart';

Future<void> main() async {
  final output = Directory('../artifacts/device-sync-phone');
  await output.create(recursive: true);
  await integrationDriver(
    responseDataCallback: (data) async {
      if (data != null) {
        await File('${output.path}/result.json')
            .writeAsString(jsonEncode(data));
      }
    },
    onScreenshot: (name, bytes, [args]) async {
      if (!RegExp(r'^[a-z-]+$').hasMatch(name)) return false;
      await File('${output.path}/$name.png').writeAsBytes(bytes);
      return bytes.isNotEmpty;
    },
  );
}
