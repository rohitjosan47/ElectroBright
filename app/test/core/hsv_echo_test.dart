import 'package:electrobright/core/color/hsv.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('every point of the square survives its own 8-bit echo', () {
    int moved = 0;
    for (double h = 0; h < 360; h += 7.5) {
      for (double s = 0; s <= 1; s += 0.05) {
        for (double v = 0; v <= 1; v += 0.05) {
          final Hsv picked = Hsv(h, s, v);
          final List<int> c = picked.toRgb8();
          if (Hsv.fromRgb8(c[0], c[1], c[2], previous: picked) != picked) {
            moved++;
          }
        }
      }
    }
    expect(moved, 0);
  });

  test('black keeps hue and saturation, never red', () {
    const Hsv picked = Hsv(200, 0.8, 0.6);
    expect(Hsv.fromRgb8(0, 0, 0, previous: picked), const Hsv(200, 0.8, 0));
  });
}
