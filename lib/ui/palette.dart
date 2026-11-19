import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

abstract final class Palette {
  static const background = Color(0xFFF7F7F7);
  static const ink = Color(0xFF252525);
  static const muted = Color(0xFF6A6A6C);
  static const line = Color(0xFFDEDEDF);
  static const control = Color(0xFF373739);
  static const amber = Color(0xFF705832);
  static const red = Color(0xFFAE4D45);
  static const sidebar = Color(0xFFF0F0F1);

  static const surface = Color(0xFFFCFCFC);
  static const selection = Color(0xFFDDDDDF);
  static const canvas = Color(0xFF202020);

  static ThemeData get theme => ThemeData(
    useMaterial3: true,
    scaffoldBackgroundColor: background,
    colorScheme:
        ColorScheme.fromSeed(
          seedColor: control,
          brightness: Brightness.light,
          dynamicSchemeVariant: DynamicSchemeVariant.monochrome,
        ).copyWith(
          primary: control,
          surface: Colors.white,
          onSurface: ink,
          outlineVariant: line,
        ),
    fontFamily: switch (defaultTargetPlatform) {
      TargetPlatform.macOS => '.AppleSystemUIFont',
      TargetPlatform.windows => 'Segoe UI',
      _ => null,
    },
    fontFamilyFallback: const [
      'PingFang SC',
      'Microsoft YaHei',
      'Noto Sans CJK SC',
      'sans-serif',
    ],
    textTheme: const TextTheme(
      bodyMedium: TextStyle(fontSize: 14, color: ink),
      bodySmall: TextStyle(fontSize: 12, color: muted),
    ),
    dividerTheme: const DividerThemeData(color: line, thickness: 1, space: 1),
    visualDensity: VisualDensity.compact,
    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        iconSize: 17,
        minimumSize: const Size(32, 32),
        padding: const EdgeInsets.all(6),
        foregroundColor: ink,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: ink),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        textStyle: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          fontFamilyFallback: ['PingFang SC', 'Microsoft YaHei', 'sans-serif'],
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        side: const BorderSide(color: line),
        foregroundColor: ink,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: background,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide.none,
      ),
      hintStyle: const TextStyle(fontSize: 13, color: muted),
    ),
    tooltipTheme: const TooltipThemeData(
      waitDuration: Duration(milliseconds: 500),
    ),
    splashFactory: NoSplash.splashFactory,
  );
}
