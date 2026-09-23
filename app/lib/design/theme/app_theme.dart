import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../tokens/palette.dart';

/// App-wide Material themes (light and dark follow the system).
abstract final class AppTheme {
  static ThemeData light() => _build(Brightness.light);

  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final bool dark = brightness == Brightness.dark;
    final Color canvas = dark ? Palette.canvasDark : Palette.canvasLight;
    final ColorScheme scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF5B8CFF),
      brightness: brightness,
    ).copyWith(surface: canvas);
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: canvas,
      canvasColor: canvas,
      // San Francisco on iOS (platform default); bundled Inter elsewhere.
      fontFamily: defaultTargetPlatform == TargetPlatform.iOS ? null : 'Inter',
      splashFactory: NoSplash.splashFactory,
    );
  }
}
