import 'package:flutter/material.dart';

import 'glass.dart';

/// SkyFindr design tokens: calm blue on light gray, deep navy in dark mode.
class Palette {
  final Color background;
  final Color surface;
  final Color border;
  final Color primary;
  final Color onPrimary;
  final Color tint; // light blue fills: badges, notes, selected nav pill
  final Color text;
  final Color muted;
  final Color success;
  final Color warning;
  final Color warningFill;

  const Palette({
    required this.background,
    required this.surface,
    required this.border,
    required this.primary,
    required this.onPrimary,
    required this.tint,
    required this.text,
    required this.muted,
    required this.success,
    required this.warning,
    required this.warningFill,
  });

  static const light = Palette(
    background: Color(0xFFF3F5F9),
    surface: Colors.white,
    border: Color(0xFFE2E7EF),
    primary: Color(0xFF1E5BD7),
    onPrimary: Colors.white,
    tint: Color(0xFFE8EFFD),
    text: Color(0xFF0E1726),
    muted: Color(0xFF5D6778),
    success: Color(0xFF1F9D55),
    warning: Color(0xFFB7791F),
    warningFill: Color(0xFFFDF3DC),
  );

  static const dark = Palette(
    background: Color(0xFF0A1630),
    surface: Color(0xFF0F2042),
    border: Color(0xFF1D325C),
    primary: Color(0xFF4C86F2),
    onPrimary: Colors.white,
    tint: Color(0xFF16305E),
    text: Color(0xFFF1F5FB),
    muted: Color(0xFF9AA8C2),
    success: Color(0xFF3CCB7F),
    warning: Color(0xFFF2B84B),
    warningFill: Color(0xFF3A2F17),
  );

  static Palette of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? dark : light;
}

ThemeData buildTheme(Brightness brightness) {
  final p = brightness == Brightness.dark ? Palette.dark : Palette.light;
  final scheme = ColorScheme.fromSeed(seedColor: p.primary, brightness: brightness).copyWith(
    primary: p.primary,
    onPrimary: p.onPrimary,
    surface: p.surface,
    onSurface: p.text,
    primaryContainer: p.tint,
    outline: p.border,
    outlineVariant: p.border,
  );
  final base = ThemeData(colorScheme: scheme, useMaterial3: true, brightness: brightness);
  final text = base.textTheme.apply(bodyColor: p.text, displayColor: p.text);
  final radius = BorderRadius.circular(12);
  OutlineInputBorder border(Color c) => OutlineInputBorder(borderRadius: radius, borderSide: BorderSide(color: c));

  return base.copyWith(
    scaffoldBackgroundColor: p.background,
    textTheme: text.copyWith(
      headlineMedium: text.headlineMedium?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.8, height: 1.15),
      headlineSmall: text.headlineSmall?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.5),
      titleMedium: text.titleMedium?.copyWith(fontWeight: FontWeight.w600),
      bodySmall: text.bodySmall?.copyWith(color: p.muted),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: p.background,
      foregroundColor: p.text,
      elevation: 0,
      scrolledUnderElevation: 0,
      titleTextStyle: text.titleMedium?.copyWith(fontSize: 16),
    ),
    cardTheme: CardThemeData(
      color: p.surface,
      elevation: 0,
      margin: const EdgeInsets.symmetric(vertical: 6),
      shape: RoundedRectangleBorder(borderRadius: radius, side: BorderSide(color: p.border)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: p.surface,
      border: border(p.border),
      enabledBorder: border(p.border),
      focusedBorder: border(p.primary),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      hintStyle: TextStyle(color: p.muted),
    ),
    // Liquid glass buttons (glass.dart): translucent tint + blur, sheen and rim light on top.
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: p.primary.withValues(alpha: 0.88),
        foregroundColor: p.onPrimary,
        minimumSize: const Size(64, 52),
        shape: RoundedRectangleBorder(borderRadius: radius),
        textStyle: TextStyle(fontFamily: text.labelLarge?.fontFamily, fontWeight: FontWeight.w600, fontSize: 15),
        elevation: 3,
        shadowColor: p.primary.withValues(alpha: 0.5),
      ).copyWith(backgroundBuilder: glassBuilder(RoundedRectangleBorder(borderRadius: radius))),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: p.primary,
        minimumSize: const Size(64, 50),
        side: BorderSide(color: p.border.withValues(alpha: 0.8)),
        backgroundColor: p.surface.withValues(alpha: 0.6),
        shape: RoundedRectangleBorder(borderRadius: radius),
        textStyle: TextStyle(fontFamily: text.labelLarge?.fontFamily, fontWeight: FontWeight.w600),
        elevation: 1,
        shadowColor: Colors.black.withValues(alpha: 0.2),
      ).copyWith(backgroundBuilder: glassBuilder(RoundedRectangleBorder(borderRadius: radius))),
    ),
    textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(foregroundColor: p.primary)),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: p.surface,
      indicatorColor: p.tint,
      surfaceTintColor: Colors.transparent,
      height: 68,
      labelTextStyle: WidgetStateProperty.resolveWith((s) => TextStyle(
            fontSize: 11,
            fontWeight: s.contains(WidgetState.selected) ? FontWeight.w600 : FontWeight.w400,
            color: s.contains(WidgetState.selected) ? p.primary : p.muted,
          )),
      iconTheme: WidgetStateProperty.resolveWith(
          (s) => IconThemeData(color: s.contains(WidgetState.selected) ? p.primary : p.muted, size: 22)),
    ),
    dividerTheme: DividerThemeData(color: p.border, space: 1),
    chipTheme: base.chipTheme.copyWith(
      backgroundColor: p.surface,
      side: BorderSide(color: p.border),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      labelStyle: TextStyle(color: p.text, fontSize: 12, fontFamily: text.labelLarge?.fontFamily),
    ),
    bottomSheetTheme: BottomSheetThemeData(backgroundColor: p.surface, surfaceTintColor: Colors.transparent),
    dialogTheme: DialogThemeData(backgroundColor: p.surface, surfaceTintColor: Colors.transparent),
  );
}
