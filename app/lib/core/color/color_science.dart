import 'dart:math' as math;

import 'package:meta/meta.dart';

/// Linear-light RGB, each channel 0..1 (may exceed 1 before normalising).
@immutable
final class LinearRgb {
  const LinearRgb(this.r, this.g, this.b);
  final double r;
  final double g;
  final double b;

  LinearRgb operator +(LinearRgb o) => LinearRgb(r + o.r, g + o.g, b + o.b);
  LinearRgb operator *(double k) => LinearRgb(r * k, g * k, b * k);
  double get max => math.max(r, math.max(g, b));

  /// Scaled so the largest channel is 1 (black stays black).
  LinearRgb normalized() {
    final double m = max;
    return m <= 1e-9 ? const LinearRgb(0, 0, 0) : this * (1 / m);
  }

  LinearRgb nonNegative() =>
      LinearRgb(math.max(r, 0), math.max(g, 0), math.max(b, 0));

  LinearRgb clamp01() =>
      LinearRgb(r.clamp(0.0, 1.0), g.clamp(0.0, 1.0), b.clamp(0.0, 1.0));

  /// Relative luminance (WCAG).
  double get luminance => 0.2126 * r + 0.7152 * g + 0.0722 * b;

  @override
  String toString() =>
      'LinearRgb(${r.toStringAsFixed(3)}, ${g.toStringAsFixed(3)}, ${b.toStringAsFixed(3)})';
}

/// OKLCH (Björn Ottosson): perceptual lightness, chroma, hue (degrees).
@immutable
final class Oklch {
  const Oklch(this.l, this.c, this.h);
  final double l;
  final double c;
  final double h;

  Oklch copyWith({double? l, double? c, double? h}) =>
      Oklch(l ?? this.l, c ?? this.c, h ?? this.h);

  @override
  String toString() =>
      'Oklch(${l.toStringAsFixed(3)}, ${c.toStringAsFixed(3)}, ${h.toStringAsFixed(1)})';
}

abstract final class ColorScience {
  // ---- sRGB transfer ------------------------------------------------------------
  static double srgbToLinear(double v) =>
      v <= 0.04045 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();

  static double linearToSrgb(double v) {
    final double x = v.clamp(0.0, 1.0);
    return x <= 0.0031308
        ? 12.92 * x
        : 1.055 * math.pow(x, 1 / 2.4).toDouble() - 0.055;
  }

  static LinearRgb fromSrgb8(int r, int g, int b) => LinearRgb(
    srgbToLinear(r / 255),
    srgbToLinear(g / 255),
    srgbToLinear(b / 255),
  );

  /// ARGB int (opaque) from linear RGB.
  static int toArgb(LinearRgb c) {
    int ch(double v) => (linearToSrgb(v) * 255).round().clamp(0, 255);
    return 0xFF000000 | (ch(c.r) << 16) | (ch(c.g) << 8) | ch(c.b);
  }

  static LinearRgb fromArgb(int argb) =>
      fromSrgb8((argb >> 16) & 0xFF, (argb >> 8) & 0xFF, argb & 0xFF);

  // ---- Perceptual device encoding (firmware GAMMA=2.2) ----------------------------
  static double levelToLinear(int byte) => math.pow(byte / 255, 2.2).toDouble();
  static int linearToLevel(double l) =>
      (math.pow(l.clamp(0.0, 1.0), 1 / 2.2) * 255).round();

  // ---- OKLab ------------------------------------------------------------------------
  static Oklch toOklch(LinearRgb c) {
    final double l =
        0.4122214708 * c.r + 0.5363325363 * c.g + 0.0514459929 * c.b;
    final double m =
        0.2119034982 * c.r + 0.6806995451 * c.g + 0.1073969566 * c.b;
    final double s =
        0.0883024619 * c.r + 0.2817188376 * c.g + 0.6299787005 * c.b;
    final double l_ = _cbrt(l), m_ = _cbrt(m), s_ = _cbrt(s);
    final double ll = 0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_;
    final double a = 1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_;
    final double bb = 0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_;
    final double chroma = math.sqrt(a * a + bb * bb);
    double hue = math.atan2(bb, a) * 180 / math.pi;
    if (hue < 0) hue += 360;
    return Oklch(ll, chroma, hue);
  }

  static LinearRgb fromOklch(Oklch o) {
    final double hr = o.h * math.pi / 180;
    final double a = o.c * math.cos(hr);
    final double b = o.c * math.sin(hr);
    final double l_ = o.l + 0.3963377774 * a + 0.2158037573 * b;
    final double m_ = o.l - 0.1055613458 * a - 0.0638541728 * b;
    final double s_ = o.l - 0.0894841775 * a - 1.2914855480 * b;
    final double l = l_ * l_ * l_, m = m_ * m_ * m_, s = s_ * s_ * s_;
    return LinearRgb(
      4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
      -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
      -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s,
    );
  }

  static bool inGamut(LinearRgb c) =>
      c.r >= -1e-4 &&
      c.g >= -1e-4 &&
      c.b >= -1e-4 &&
      c.r <= 1 + 1e-4 &&
      c.g <= 1 + 1e-4 &&
      c.b <= 1 + 1e-4;

  /// Reduces chroma (keeping L and h) until the colour fits sRGB.
  static Oklch toGamut(Oklch o) {
    if (inGamut(fromOklch(o))) return o;
    double lo = 0, hi = o.c;
    for (int i = 0; i < 20; i++) {
      final double mid = (lo + hi) / 2;
      if (inGamut(fromOklch(o.copyWith(c: mid)))) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    return o.copyWith(c: lo);
  }

  /// Interpolates in OKLab (no muddy midpoints).
  static Oklch lerp(Oklch a, Oklch b, double t) {
    double dh = b.h - a.h;
    if (dh > 180) dh -= 360;
    if (dh < -180) dh += 360;
    // Near-grey colours have meaningless hue: take the other's hue.
    final double h = a.c < 0.01
        ? b.h
        : b.c < 0.01
        ? a.h
        : (a.h + dh * t) % 360;
    return Oklch(a.l + (b.l - a.l) * t, a.c + (b.c - a.c) * t, h);
  }

  // ---- Colour temperature ----------------------------------------------------------
  /// Planckian locus chromaticity (Kim et al. cubic), 1667..25000 K.
  static (double, double) kelvinToXy(double k) {
    final double t = k.clamp(1667.0, 25000.0);
    final double x = t <= 4000
        ? -0.2661239e9 / (t * t * t) -
              0.2343589e6 / (t * t) +
              0.8776956e3 / t +
              0.179910
        : -3.0258469e9 / (t * t * t) +
              2.1070379e6 / (t * t) +
              0.2226347e3 / t +
              0.240390;
    final double y = t <= 2222
        ? -1.1063814 * x * x * x -
              1.34811020 * x * x +
              2.18555832 * x -
              0.20219683
        : t <= 4000
        ? -0.9549476 * x * x * x -
              1.37418593 * x * x +
              2.09137015 * x -
              0.16748867
        : 3.0817580 * x * x * x -
              5.87338670 * x * x +
              3.75112997 * x -
              0.37001483;
    return (x, y);
  }

  /// Linear sRGB of a blackbody at [k], normalised so the max channel is 1.
  static LinearRgb kelvinToLinear(double k) {
    final (double x, double y) = kelvinToXy(k);
    final double bigX = x / y, bigZ = (1 - x - y) / y;
    return LinearRgb(
      3.2406 * bigX - 1.5372 - 0.4986 * bigZ,
      -0.9689 * bigX + 1.8758 + 0.0415 * bigZ,
      0.0557 * bigX - 0.2040 + 1.0570 * bigZ,
    ).nonNegative().normalized();
  }

  /// Correlated colour temperature estimate (McCamy) of a linear colour.
  static double estimateKelvin(LinearRgb c) {
    final double bigX = 0.4124 * c.r + 0.3576 * c.g + 0.1805 * c.b;
    final double bigY = 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b;
    final double bigZ = 0.0193 * c.r + 0.1192 * c.g + 0.9505 * c.b;
    final double sum = bigX + bigY + bigZ;
    if (sum <= 1e-9) return 6500;
    final double x = bigX / sum, y = bigY / sum;
    final double n = (x - 0.3320) / (0.1858 - y);
    return 449 * n * n * n + 3525 * n * n + 6823.3 * n + 5520.33;
  }

  // ---- Contrast -------------------------------------------------------------------------
  static double contrast(LinearRgb a, LinearRgb b) {
    final double la = a.luminance, lb = b.luminance;
    final double hi = math.max(la, lb), lo = math.min(la, lb);
    return (hi + 0.05) / (lo + 0.05);
  }

  static double _cbrt(double v) =>
      v < 0 ? -math.pow(-v, 1 / 3).toDouble() : math.pow(v, 1 / 3).toDouble();
}
