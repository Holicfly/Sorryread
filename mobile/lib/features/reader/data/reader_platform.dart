import 'package:flutter/services.dart';

class ReaderBatteryStatus {
  const ReaderBatteryStatus(this.level, this.charging);
  final int? level;
  final bool charging;
}

class ReaderPlatform {
  static const channel = MethodChannel('sorryread/reader');

  Future<double> bottomClearance() async {
    try {
      return ((await channel.invokeMethod<num>('readerBottomClearance'))
                  ?.toDouble() ??
              12)
          .clamp(12, 40);
    } on MissingPluginException {
      return 12;
    } on PlatformException {
      return 12;
    }
  }

  Future<void> fullscreen(bool enabled) async {
    try {
      await channel.invokeMethod<void>('readerFullscreen', enabled);
    } on MissingPluginException {
      // Non-Android platforms and widget fixtures have no native window.
    } on PlatformException {
      // SystemChrome still provides immersive mode if cutout control fails.
    }
  }

  Future<ReaderBatteryStatus> batteryStatus() async {
    try {
      final status = await channel.invokeMapMethod<String, dynamic>(
        'batteryStatus',
      );
      if (status != null) {
        return ReaderBatteryStatus(
          status['level'] as int?,
          status['charging'] == true,
        );
      }
    } on MissingPluginException {
      // Older native bridges and widget fixtures only expose the level.
    } on PlatformException {
      // Keep the reading status available if charging state cannot be read.
    }
    return ReaderBatteryStatus(await battery(), false);
  }

  Future<int?> battery() async {
    try {
      return await channel.invokeMethod<int>('battery');
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  Future<void> brightness(double? value) async {
    try {
      await channel.invokeMethod<void>('brightness', value);
    } on MissingPluginException {
      /* Widget tests have no window. */
    }
  }

  Future<String> decode(String charset, Uint8List bytes) async => (await channel
      .invokeMethod<String>('decode', {'charset': charset, 'bytes': bytes}))!;
  Future<Uint8List?> importFont() =>
      channel.invokeMethod<Uint8List>('importFont');
}
