import 'package:flutter/material.dart';

abstract final class AppTheme {
  static final light = _build(Brightness.light);
  static final dark = _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final colors =
        ColorScheme.fromSeed(
          seedColor: const Color(0xFF2E6B53),
          brightness: brightness,
        ).copyWith(
          primary: dark ? const Color(0xFFA3D1B7) : const Color(0xFF2E6B53),
          onPrimary: dark ? const Color(0xFF163E2D) : Colors.white,
          primaryContainer: dark
              ? const Color(0xFF263D32)
              : const Color(0xFFE0EBE2),
          surface: dark ? const Color(0xFF202622) : const Color(0xFFFFFDF9),
          onSurface: dark ? const Color(0xFFE7EAE4) : const Color(0xFF242D28),
          onSurfaceVariant: dark
              ? const Color(0xFFADB7AE)
              : const Color(0xFF747A73),
          outlineVariant: dark
              ? const Color(0xFF343E37)
              : const Color(0xFFEAE7DF),
        );
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: colors,
      scaffoldBackgroundColor: dark
          ? const Color(0xFF171D19)
          : const Color(0xFFF5F3EE),
    );
    final text = base.textTheme.apply(
      bodyColor: colors.onSurface,
      displayColor: colors.onSurface,
    );
    return base.copyWith(
      textTheme: text.copyWith(
        headlineLarge: text.headlineLarge?.copyWith(
          fontSize: 30,
          fontWeight: FontWeight.w700,
        ),
        titleLarge: text.titleLarge?.copyWith(
          fontSize: 21,
          fontWeight: FontWeight.w600,
        ),
        titleMedium: text.titleMedium?.copyWith(
          fontSize: 16,
          fontWeight: FontWeight.w500,
        ),
        bodyMedium: text.bodyMedium?.copyWith(fontSize: 14, height: 1.5),
        bodySmall: text.bodySmall?.copyWith(
          fontSize: 12,
          height: 1.4,
          color: colors.onSurfaceVariant,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        height: 72,
        backgroundColor: colors.surface,
        surfaceTintColor: Colors.transparent,
        indicatorColor: colors.primaryContainer,
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => TextStyle(
            fontSize: 12,
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w600
                : FontWeight.w400,
            color: states.contains(WidgetState.selected)
                ? colors.primary
                : colors.onSurfaceVariant,
          ),
        ),
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            size: 26,
            color: states.contains(WidgetState.selected)
                ? colors.primary
                : colors.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
