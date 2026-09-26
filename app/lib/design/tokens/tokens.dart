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
/// clear water in a glass tube, the same in every light — never the light's
/// colour — with fixed ink on it (so the ink never flips as the fill
/// changes). Completely transparent: it has no colour of its own, takes the
/// colour of whatever is behind it, refracts it and catches the light
/// (meniscus, glint, bright edges).
abstract final class PillFill {
  /// Dark theme: white ink, a faint periwinkle glow around the water.
  static const PillGlass dark = PillGlass(
    ink: Color(0xFFFFFFFF),
    halo: Color(0xFF6D9AFF),
    solid: Color(0xFF394D71),
  );

  /// Light theme: navy ink, a soft bluish shadow around the water.
  static const PillGlass light = PillGlass(
    ink: Color(0xFF14204A),
    halo: Color(0xFF132C6F),
    solid: Color(0xFFBACFF3),
  );

  static PillGlass of({required bool dark}) => dark ? PillFill.dark : light;
  static Color inkOf({required bool dark}) => of(dark: dark).ink;
}

/// One theme's pill water: the [ink] on it (>= 4.5:1 over every light's
/// track, which is what shows through), the [halo] around it (a glow in
/// dark, a shadow in light) and, under Reduce Transparency only, the [solid]
/// colour it becomes.
@immutable
final class PillGlass {
  const PillGlass({required this.ink, required this.halo, required this.solid});

  final Color ink;
  final Color halo;
  final Color solid;
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
