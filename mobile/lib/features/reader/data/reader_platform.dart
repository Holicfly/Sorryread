import 'package:flutter/services.dart';

class ReaderBatteryStatus {
  const ReaderBatteryStatus(this.level, this.charging);
  final int? level;
  final bool charging;
}

class ReaderPlatform {
  static const channel = MethodChannel('sorryread/reader');
  static const fallbackBottomClearance = 4.0;

  Future<({double navigation, double radius})> windowInsets() async {
    try {
      final value = await channel.invokeMapMethod<String, dynamic>(
        'readerWindowInsets',
      );
      return (
        navigation: (value?['navigation'] as num?)?.toDouble() ?? 0,
        radius: (value?['radius'] as num?)?.toDouble() ?? 0,
      );
    } on MissingPluginException {
      return (navigation: 0.0, radius: 0.0);
    } on PlatformException {
      return (navigation: 0.0, radius: 0.0);
    }
  }

  Future<double> bottomClearance() async {
    try {
      return ((await channel.invokeMethod<num>('readerBottomClearance'))
                  ?.toDouble() ??
              fallbackBottomClearance)
          .clamp(fallbackBottomClearance, double.infinity);
    } on MissingPluginException {
      return fallbackBottomClearance;
    } on PlatformException {
      return fallbackBottomClearance;
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
