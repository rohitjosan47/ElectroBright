import 'package:meta/meta.dart';

/// An 8-bit RGBW value as the ElectroBright protocol carries it
/// (perceptually encoded, 0..255 per channel).
@immutable
final class Rgbw {
  const Rgbw(this.r, this.g, this.b, this.w);

  static const Rgbw black = Rgbw(0, 0, 0, 0);

  final int r;
  final int g;
  final int b;
  final int w;

  bool get isValid => _ok(r) && _ok(g) && _ok(b) && _ok(w);

  static bool _ok(int v) => v >= 0 && v <= 255;

  Rgbw copyWith({int? r, int? g, int? b, int? w}) =>
      Rgbw(r ?? this.r, g ?? this.g, b ?? this.b, w ?? this.w);

  List<int> toList() => <int>[r, g, b, w];

  @override
  bool operator ==(Object other) =>
      other is Rgbw &&
      other.r == r &&
      other.g == g &&
      other.b == b &&
      other.w == w;

  @override
  int get hashCode => Object.hash(r, g, b, w);

  @override
  String toString() => 'Rgbw($r, $g, $b, $w)';
}
