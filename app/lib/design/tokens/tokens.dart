import 'package:flutter/widgets.dart';

/// Spacing on a 4-pt grid.
abstract final class Space {
  static const double xxs = 4;
  static const double xs = 8;
  static const double s = 12;
  static const double m = 16;
  static const double l = 20;
  static const double xl = 24;
  static const double xxl = 32;

  /// Horizontal page gutter.
  static const double gutter = 20;
}

/// The fill of every pill slider (brightness, speed, frequency, level):
/// frosted brand glass, periwinkle from the theme seed ([seed]), one fixed
/// look per theme — never the light's colour — with fixed ink on it (so the
/// ink never flips as the fill changes).
abstract final class PillFill {
  /// The brand's theme seed (periwinkle; the logo glows cyan into indigo).
  static const Color seed = Color(0xFF5B8CFF);

  /// Dark theme: a luminous tint over the dark track, a soft periwinkle
  /// glow, deep navy ink.
  static const PillGlass dark = PillGlass(
    deep: Color(0xFF82A6F3),
    base: Color(0xFF94B6FF),
    bright: Color(0xFFACC7FF),
    opacity: 0.86,
    ink: Color(0xFF0B1030),
    halo: Color(0xFF6D9AFF),
  );

  /// Light theme: a clearer, more saturated tint over the light track, a
  /// soft bluish shadow, white ink.
  static const PillGlass light = PillGlass(
    deep: Color(0xFF1137AC),
    base: Color(0xFF1E47BC),
    bright: Color(0xFF345BBE),
    opacity: 0.9,
    ink: Color(0xFFFFFFFF),
    halo: Color(0xFF132C6F),
  );

  static PillGlass of({required bool dark}) => dark ? PillFill.dark : light;
  static Color inkOf({required bool dark}) => of(dark: dark).ink;
}

/// One theme's pill glass: the tint from its start ([deep]) through [base]
/// to its leading end ([bright]), all the seed's hue at different
/// lightnesses, laid on the track at [opacity] (the glass beneath shows
/// through); the [ink] on it (>= 4.5:1 on every part of the fill, over any
/// canvas); and the [halo] around it (a glow in dark, a shadow in light).
@immutable
final class PillGlass {
  const PillGlass({
    required this.deep,
    required this.base,
    required this.bright,
    required this.opacity,
    required this.ink,
    required this.halo,
  });

  final Color deep;
  final Color base;
  final Color bright;
  final double opacity;
  final Color ink;
  final Color halo;
}

/// Continuous-corner radii; nested shapes use concentric radii
/// (outer = inner + padding).
abstract final class Radii {
  static const double small = 12;
  static const double medium = 20;
  static const double large = 28;
  static const double sheet = 34;
  static const double capsule = 999;
}

/// Spring motion tokens (time-based: identical at 60 and 120 Hz).
abstract final class Motion {
  static const SpringDescription snappy = SpringDescription(
    mass: 1,
    stiffness: 520,
    damping: 44,
  );
  static const SpringDescription smooth = SpringDescription(
    mass: 1,
    stiffness: 260,
    damping: 32,
  );
  static const SpringDescription bouncy = SpringDescription(
    mass: 1,
    stiffness: 300,
    damping: 20,
  );
  static const SpringDescription liquid = SpringDescription(
    mass: 1,
    stiffness: 180,
    damping: 18,
  );

  static const Duration fast = Duration(milliseconds: 180);
  static const Duration medium = Duration(milliseconds: 320);
  static const Duration tone = Duration(milliseconds: 450);
  static const Curve emphasized = Cubic(0.2, 0, 0, 1);

  /// True when the user asked for reduced motion.
  static bool reduced(BuildContext context) =>
      MediaQuery.maybeDisableAnimationsOf(context) ?? false;
}
