import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Color Math & Geometry Precision Tests', () {
    test('Polar angle to hue degrees correctly maps all 4 quadrants', () {
      double angleToHue(double dx, double dy) {
        final rad = math.atan2(dy, dx);
        double deg = rad * 180 / math.pi;
        if (deg < 0) deg += 360;
        return deg;
      }

      // Quadrant 1 (+dx, +dy) -> 0° to 90° (Red to Yellow/Green)
      expect(angleToHue(10, 0), closeTo(0.0, 0.001));
      expect(angleToHue(10, 10), closeTo(45.0, 0.001));
      expect(angleToHue(0, 10), closeTo(90.0, 0.001));

      // Quadrant 2 (-dx, +dy) -> 90° to 180° (Green to Cyan)
      expect(angleToHue(-10, 10), closeTo(135.0, 0.001));
      expect(angleToHue(-10, 0), closeTo(180.0, 0.001));

      // Quadrant 3 (-dx, -dy) -> 180° to 270° (Cyan to Blue)
      expect(angleToHue(-10, -10), closeTo(225.0, 0.001));
      expect(angleToHue(0, -10), closeTo(270.0, 0.001));

      // Quadrant 4 (+dx, -dy) -> 270° to 360° (Blue to Magenta to Red)
      expect(angleToHue(10, -10), closeTo(315.0, 0.001));
    });

    test('Inner square normalized coordinate mapping with strict clamping', () {
      const sqHalf = 59.0;

      (double, double) touchToSV(double dx, double dy) {
        final clampedX = dx.clamp(-sqHalf, sqHalf);
        final clampedY = dy.clamp(-sqHalf, sqHalf);
        final s = ((clampedX + sqHalf) / (sqHalf * 2)).clamp(0.0, 1.0);
        final v = (1.0 - ((clampedY + sqHalf) / (sqHalf * 2))).clamp(0.0, 1.0);
        return (s, v);
      }

      // Top-Left corner -> S=0, V=1 (White)
      final (sTopLeft, vTopLeft) = touchToSV(-sqHalf, -sqHalf);
      expect(sTopLeft, closeTo(0.0, 0.001));
      expect(vTopLeft, closeTo(1.0, 0.001));

      // Top-Right corner -> S=1, V=1 (Pure Saturated Hue)
      final (sTopRight, vTopRight) = touchToSV(sqHalf, -sqHalf);
      expect(sTopRight, closeTo(1.0, 0.001));
      expect(vTopRight, closeTo(1.0, 0.001));

      // Bottom-Left corner -> S=0, V=0 (Black)
      final (sBottomLeft, vBottomLeft) = touchToSV(-sqHalf, sqHalf);
      expect(sBottomLeft, closeTo(0.0, 0.001));
      expect(vBottomLeft, closeTo(0.0, 0.001));

      // Center -> S=0.5, V=0.5
      final (sCenter, vCenter) = touchToSV(0, 0);
      expect(sCenter, closeTo(0.5, 0.001));
      expect(vCenter, closeTo(0.5, 0.001));

      // Boundary overflows are clamped smoothly without NaN or jump
      final (sOverflow, vOverflow) = touchToSV(200.0, -300.0);
      expect(sOverflow, 1.0);
      expect(vOverflow, 1.0);
    });

    test('Hue retention algorithm prevents collapse when color approaches grayscale/black', () {
      double currentHue = 210.0; // Selected Blue hue

      double syncHue(int r, int g, int b) {
        final hsv = HSVColor.fromColor(Color.fromARGB(255, r, g, b));
        if (hsv.saturation > 0.05 && hsv.value > 0.05) {
          return hsv.hue;
        }
        return currentHue; // Preserves selected hue!
      }

      // Saturated Blue (R: 0, G: 128, B: 255) updates hue
      currentHue = syncHue(0, 128, 255);
      expect(currentHue, closeTo(210.0, 1.0));

      // Pure Black (R: 0, G: 0, B: 0) -> does NOT collapse to 0.0 (Red)!
      final blackHue = syncHue(0, 0, 0);
      expect(blackHue, closeTo(currentHue, 0.001));

      // Pure White (R: 255, G: 255, B: 255) -> does NOT collapse to 0.0 (Red)!
      final whiteHue = syncHue(255, 255, 255);
      expect(whiteHue, closeTo(currentHue, 0.001));

      // Muted Gray (R: 128, G: 128, B: 128) -> does NOT collapse to 0.0 (Red)!
      final grayHue = syncHue(128, 128, 128);
      expect(grayHue, closeTo(currentHue, 0.001));

      // Saturated Amber (R: 255, G: 165, B: 0) -> updates hue to ~38.8°
      currentHue = syncHue(255, 165, 0);
      expect(currentHue, closeTo(38.8, 1.0));
    });
  });
}
