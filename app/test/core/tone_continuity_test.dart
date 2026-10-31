import 'dart:math' as math;

import 'package:electrobright/core/color/color_science.dart';
import 'package:electrobright/core/color/hsv.dart';
import 'package:electrobright/core/color/light_tone.dart';
import 'package:flutter_test/flutter_test.dart';

/// Perceptual distance (OKLab) between two ARGB colours; about 0.02 is
/// the smallest difference the eye notices.
double _step(int a, int b) {
  final Oklch x = ColorScience.toOklch(ColorScience.fromArgb(a));
  final Oklch y = ColorScience.toOklch(ColorScience.fromArgb(b));
  final double ax = x.c * math.cos(x.h * math.pi / 180);
  final double bx = x.c * math.sin(x.h * math.pi / 180);
  final double ay = y.c * math.cos(y.h * math.pi / 180);
  final double by = y.c * math.sin(y.h * math.pi / 180);
  final double dl = x.l - y.l, da = ax - ay, db = bx - by;
  return math.sqrt(dl * dl + da * da + db * db);
}

LightTone _tone(Hsv hsv, {required bool dark}) {
  final List<double> rgb = hsv.copyWith(v: 1).toRgb();
  final LinearRgb lin = LinearRgb(
    math.pow(rgb[0], 2.2).toDouble(),
    math.pow(rgb[1], 2.2).toDouble(),
    math.pow(rgb[2], 2.2).toDouble(),
  );
  return LightTone.derive(
    DisplayColor(lin.normalized(), hsv.v, off: hsv.v <= 0),
    dark: dark,
  );
}

void main() {
  for (final bool dark in <bool>[false, true]) {
    test(
      'dragging across the square never jumps the palette (dark: $dark)',
      () {
        double worst = 0;
        for (double h = 0; h < 360; h += 15) {
          // Saturation: grey to full, at full value; value: full to black.
          final List<Hsv> path = <Hsv>[
            for (int i = 0; i <= 200; i++) Hsv(h, i / 200, 1),
            for (int i = 200; i >= 0; i--) Hsv(h, 1, i / 200),
          ];
          for (int i = 1; i < path.length; i++) {
            final LightTone a = _tone(path[i - 1], dark: dark);
            final LightTone b = _tone(path[i], dark: dark);
            for (final (int x, int y) in <(int, int)>[
              (a.canvas.first, b.canvas.first),
              (a.tint, b.tint),
              (a.accent, b.accent),
              (a.glow, b.glow),
            ]) {
              worst = math.max(worst, _step(x, y));
            }
          }
        }
        // A 0.5 % step of the finger never moves a colour visibly.
        expect(worst, lessThan(0.02));
      },
    );
  }
}
