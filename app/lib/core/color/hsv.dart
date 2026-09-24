import 'dart:math' as math;

import 'package:meta/meta.dart';

/// HSV of a picked colour (hue 0..360, saturation/value 0..1). Its 8-bit RGB
/// is exactly what the colour wheel shows and what an RGB light receives.
@immutable
final class Hsv {
  const Hsv(this.h, this.s, this.v);
  final double h;
  final double s;
  final double v;

  /// 8-bit RGB (standard HSV -> RGB).
  List<int> toRgb8() {
    final double c = v * s;
    final double hp = (h % 360) / 60;
    final double x = c * (1 - ((hp % 2) - 1).abs());
    final (double r, double g, double b) = switch (hp.floor()) {
      0 => (c, x, 0.0),
      1 => (x, c, 0.0),
      2 => (0.0, c, x),
      3 => (0.0, x, c),
      4 => (x, 0.0, c),
      _ => (c, 0.0, x),
    };
    final double m = v - c;
    int byte(double t) => ((t + m) * 255).round().clamp(0, 255);
    return <int>[byte(r), byte(g), byte(b)];
  }

  /// HSV of 8-bit RGB. Keeps [previous]'s hue when the colour is (near) grey
  /// or black, so the hue never snaps to red while the user drags into a
  /// corner or a light reports white.
  static Hsv fromRgb8(int r, int g, int b, {Hsv? previous}) {
    final double rf = r / 255, gf = g / 255, bf = b / 255;
    final double mx = math.max(rf, math.max(gf, bf));
    final double mn = math.min(rf, math.min(gf, bf));
    final double d = mx - mn;
    double h = 0;
    if (d > 0) {
      if (mx == rf) {
        h = 60 * (((gf - bf) / d) % 6);
      } else if (mx == gf) {
        h = 60 * ((bf - rf) / d + 2);
      } else {
        h = 60 * ((rf - gf) / d + 4);
      }
    }
    if (h < 0) h += 360;
    final double s = mx <= 0 ? 0 : d / mx;
    final bool hueless = s <= 0.05 || mx <= 0.05;
    return Hsv(hueless && previous != null ? previous.h : h, s, mx);
  }

  Hsv copyWith({double? h, double? s, double? v}) =>
      Hsv(h ?? this.h, s ?? this.s, v ?? this.v);

  @override
  bool operator ==(Object other) =>
      other is Hsv && other.h == h && other.s == s && other.v == v;
  @override
  int get hashCode => Object.hash(h, s, v);
  @override
  String toString() =>
      'Hsv(${h.toStringAsFixed(1)}, ${s.toStringAsFixed(3)}, ${v.toStringAsFixed(3)})';
}
