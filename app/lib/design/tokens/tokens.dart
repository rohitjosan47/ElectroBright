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
