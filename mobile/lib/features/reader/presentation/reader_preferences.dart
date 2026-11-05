import 'package:flutter/material.dart';

enum PageMode { curl, scroll, none }

class ReaderPreferences {
  const ReaderPreferences({
    this.fontSize = 22,
    this.font = 'system',
    this.palette = 1,
    this.night = false,
    this.eyeCare = false,
    this.brightness,
    this.mode = PageMode.curl,
  });
  final double fontSize;
  final String font;
  final int palette;
  final bool night, eyeCare;
  final double? brightness;
  final PageMode mode;
  ReaderPreferences copyWith({
    double? fontSize,
    String? font,
    int? palette,
    bool? night,
    bool? eyeCare,
    double? brightness,
    PageMode? mode,
  }) => ReaderPreferences(
    fontSize: fontSize ?? this.fontSize,
    font: font ?? this.font,
    palette: palette ?? this.palette,
    night: night ?? this.night,
    eyeCare: eyeCare ?? this.eyeCare,
    brightness: brightness ?? this.brightness,
    mode: mode ?? this.mode,
  );
  Map<String, dynamic> toJson() => {
    'fontSize': fontSize,
    'font': font,
    'palette': palette,
    'night': night,
    'eyeCare': eyeCare,
    'brightness': brightness,
    'mode': mode.name,
  };
  factory ReaderPreferences.fromJson(Map<String, dynamic> json) =>
      ReaderPreferences(
        fontSize: ((json['fontSize'] as num?)?.toDouble() ?? 22).clamp(14, 36),
        font:
            const {
              'song',
              'hei',
              'kai',
              'sourceHan',
              'wenkai',
            }.contains(json['font'])
            ? json['font'] as String
            : 'system',
        palette: ((json['palette'] as int?) ?? 1).clamp(0, 5),
        night: json['night'] == true,
        eyeCare: json['eyeCare'] == true,
        brightness: (json['brightness'] as num?)?.toDouble().clamp(.02, 1),
        mode:
            PageMode.values.where((v) => v.name == json['mode']).firstOrNull ??
            PageMode.curl,
      );
  static const backgrounds = [
    Color(0xFFFFFDF9),
    Color(0xFFF5EEDD),
    Color(0xFFE5EFDF),
    Color(0xFFDFEAF0),
    Color(0xFF262A29),
    Color(0xFF151817),
  ];
  Color get background {
    final base = night ? backgrounds[5] : backgrounds[palette];
    if (!eyeCare) return base;
    // Warm the paper without lifting dark pages into a yellow/grey haze.
    return Color.lerp(
      base,
      isBaseDark ? const Color(0xFF1D1B17) : const Color(0xFFF1E4C9),
      isBaseDark ? .28 : .38,
    )!;
  }

  bool get isBaseDark => night || palette >= 4;

  bool get isDark => background.computeLuminance() < .15;
  Color get ink => eyeCare
      ? (isDark ? const Color(0xFFBEB9AC) : const Color(0xFF3E3A31))
      : (isDark ? const Color(0xFFC2C5BF) : const Color(0xFF30372F));
  Color get accent => isDark
      ? const Color(0xFFD2C8AD)
      : const [
          Color(0xFF756A59),
          Color(0xFF796446),
          Color(0xFF516A50),
          Color(0xFF4E6979),
          Color(0xFFC6CCBF),
          Color(0xFFD2C8AD),
        ][palette];
  Color get rail =>
      Color.alphaBlend(ink.withValues(alpha: isDark ? .12 : .08), background);
  Color get selected => Color.lerp(
    background,
    isDark ? Colors.white : const Color(0xFFFFFEF8),
    isDark ? .12 : .65,
  )!;
}
