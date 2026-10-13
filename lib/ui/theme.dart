import 'package:flutter/material.dart';

/// aiwli theme — Material 3.
///
/// - With Material You (Android 12+): DynamicColorBuilder hands us the
///   wallpaper-derived ColorScheme and everything derives from it.
/// - Fallback (non-Android / unsupported): dark-first graphite + azure static
///   schemes, precisely defined (no fromSeed) so they stay on-brand.
class AppTheme {
  AppTheme._();

  // ---- dark palette (static fallback) ----
  static const _dBg = Color(0xFF0E1116);
  static const _dSurface = Color(0xFF161B22);
  static const _dSurfaceHi = Color(0xFF1D242F);
  static const _dPrimary = Color(0xFF5B8DEF);
  static const _dOnPrimary = Color(0xFFFFFFFF);
  static const _dOnBg = Color(0xFFE6E9EF);
  static const _dOnSurfaceVar = Color(0xFF98A2B3);
  static const _dOutline = Color(0xFF2A313D);
  static const _dError = Color(0xFFF87171);
  static const _dSecondary = Color(0xFF8B5CF6);

  // ---- light palette (static fallback) ----
  static const _lBg = Color(0xFFF6F7F9);
  static const _lSurface = Color(0xFFFFFFFF);
  static const _lSurfaceHi = Color(0xFFEEF1F6);
  static const _lPrimary = Color(0xFF2563EB);
  static const _lOnPrimary = Color(0xFFFFFFFF);
  static const _lOnBg = Color(0xFF171B22);
  static const _lOnSurfaceVar = Color(0xFF5B6472);
  static const _lOutline = Color(0xFFD9DFE8);
  static const _lError = Color(0xFFDC2626);
  static const _lSecondary = Color(0xFF7C3AED);

  /// Semantic accents shared by both schemes (used directly in widgets).
  static const okDark = Color(0xFF34D399);
  static const okLight = Color(0xFF059669);
  static const warnDark = Color(0xFFFBBF24);
  static const warnLight = Color(0xFFD97706);

  static ThemeData dark([ColorScheme? dynamicScheme]) {
    final s = dynamicScheme ?? _staticDarkScheme();
    return _build(s, bg: dynamicScheme?.surface ?? _dBg, isDark: true);
  }

  static ThemeData light([ColorScheme? dynamicScheme]) {
    final s = dynamicScheme ?? _staticLightScheme();
    return _build(s, bg: dynamicScheme?.surface ?? _lBg, isDark: false);
  }

  static ColorScheme _staticDarkScheme() => const ColorScheme(
    brightness: Brightness.dark,
    primary: _dPrimary,
    onPrimary: _dOnPrimary,
    secondary: _dSecondary,
    onSecondary: _dOnPrimary,
    error: _dError,
    onError: Colors.white,
    surface: _dSurface,
    onSurface: _dOnBg,
    surfaceContainerHighest: _dSurfaceHi,
    surfaceContainerHigh: _dSurfaceHi,
    surfaceContainer: _dSurface,
    onSurfaceVariant: _dOnSurfaceVar,
    outline: _dOutline,
    outlineVariant: _dOutline,
  );

  static ColorScheme _staticLightScheme() => const ColorScheme(
    brightness: Brightness.light,
    primary: _lPrimary,
    onPrimary: _lOnPrimary,
    secondary: _lSecondary,
    onSecondary: _lOnPrimary,
    error: _lError,
    onError: Colors.white,
    surface: _lSurface,
    onSurface: _lOnBg,
    surfaceContainerHighest: _lSurfaceHi,
    surfaceContainerHigh: _lSurfaceHi,
    surfaceContainer: _lSurface,
    onSurfaceVariant: _lOnSurfaceVar,
    outline: _lOutline,
    outlineVariant: _lOutline,
  );

  static ThemeData _build(
    ColorScheme scheme, {
    required Color bg,
    required bool isDark,
  }) {
    final primary = scheme.primary;
    final onPrimary = scheme.onPrimary;
    final onBg = scheme.onSurface;
    final onSurfaceVar = scheme.onSurfaceVariant;
    final outline = scheme.outline;

    final base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: bg,
      splashFactory: InkSparkle.splashFactory,
    );

    return base.copyWith(
      appBarTheme: AppBarTheme(
        backgroundColor: bg,
        foregroundColor: onBg,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w600,
          color: onBg,
          letterSpacing: 0.2,
        ),
      ),
      cardTheme: CardThemeData(
        color: scheme.surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(
            color: outline.withValues(alpha: isDark ? 0.6 : 1),
            width: 1,
          ),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: outline.withValues(alpha: 0.5),
        thickness: 1,
        space: 1,
      ),
      tabBarTheme: TabBarThemeData(
        labelColor: primary,
        unselectedLabelColor: onSurfaceVar,
        indicatorColor: primary,
        dividerColor: Colors.transparent,
        labelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        unselectedLabelStyle: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w400,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: primary,
          foregroundColor: onPrimary,
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(11),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: primary,
          side: BorderSide(color: primary.withValues(alpha: 0.45)),
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(11),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: primary,
          textStyle: const TextStyle(fontSize: 13.5),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHighest,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(11),
          borderSide: BorderSide(color: outline),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(11),
          borderSide: BorderSide(color: outline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(11),
          borderSide: BorderSide(color: primary, width: 1.4),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 13,
          vertical: 13,
        ),
        labelStyle: TextStyle(fontSize: 13, color: onSurfaceVar),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? onPrimary : onSurfaceVar,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? primary : outline,
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: onSurfaceVar,
        titleTextStyle: TextStyle(fontSize: 14.5, color: onBg),
        subtitleTextStyle: TextStyle(fontSize: 12, color: onSurfaceVar),
      ),
    );
  }
}
