import 'package:flutter/material.dart';

/// Send — minimalist palette.
/// Indigo primary, dark surface, mint accent for "encrypted/ok" state.
class SendTheme {
  static const Color primary = Color(0xFF4F46E5);       // indigo-600
  static const Color primaryDark = Color(0xFF3730A3);   // indigo-800
  static const Color accent = Color(0xFF10B981);        // emerald-500
  static const Color bg = Color(0xFF0F172A);            // slate-900
  static const Color surface = Color(0xFF1E293B);       // slate-800
  static const Color surfaceAlt = Color(0xFF334155);    // slate-700
  static const Color textPrimary = Color(0xFFF1F5F9);   // slate-100
  static const Color textSecondary = Color(0xFF94A3B8);  // slate-400
  static const Color danger = Color(0xFFEF4444);        // red-500

  static ThemeData dark() {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: bg,
      colorScheme: const ColorScheme.dark(
        primary: primary,
        secondary: accent,
        surface: surface,
        error: danger,
        onPrimary: Colors.white,
        onSecondary: Colors.white,
        onSurface: textPrimary,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: bg,
        foregroundColor: textPrimary,
        elevation: 0,
        centerTitle: false,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        labelStyle: const TextStyle(color: textSecondary),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primary,
          foregroundColor: Colors.white,
          minimumSize: const Size.fromHeight(52),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
        ),
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: primary,
        foregroundColor: Colors.white,
      ),
      cardTheme: CardThemeData(
        color: surface,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      listTileTheme: const ListTileThemeData(
        iconColor: accent,
        textColor: textPrimary,
      ),
      textTheme: const TextTheme(
        titleLarge: TextStyle(color: textPrimary, fontWeight: FontWeight.w600, fontSize: 22),
        titleMedium: TextStyle(color: textPrimary, fontWeight: FontWeight.w600, fontSize: 18),
        bodyLarge: TextStyle(color: textPrimary, fontSize: 16),
        bodyMedium: TextStyle(color: textSecondary, fontSize: 14),
      ),
    );
  }
}
