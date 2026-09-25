import 'package:electrobright/design/controls/glass_slider.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

/// The light theme's slider fill sits inside its track like liquid in a
/// tube: inset from the rim on every side, concentric, never cut or flat.
void main() {
  const Size pill = Size(353, 56);
  const double inset = GlassSlider.lightFillInset;

  test('empty: nothing to draw', () {
    expect(GlassSlider.lightFillShapes(pill, 0), isNull);
  });

  for (final double f in <double>[0.01, 0.02, 0.5, 1]) {
    test('${(f * 100).round()} %: inside the rim, concentric, rounded', () {
      final ({RRect tube, RRect body}) s = GlassSlider.lightFillShapes(
        pill,
        f,
      )!;
      final Rect track = Offset.zero & pill;
      // The tube is the track inset by the rim width, with the concentric
      // radius (track radius − inset).
      expect(s.tube.outerRect, track.deflate(inset));
      expect(s.tube.tlRadiusX, pill.height / 2 - inset);
      // The fill never reaches the rim: inset top, bottom and left, inside
      // the tube on the right.
      final Rect b = s.body.outerRect;
      expect(b.left, inset);
      expect(b.top, inset);
      expect(b.bottom, pill.height - inset);
      expect(b.right, lessThanOrEqualTo(pill.width - inset + 1e-9));
      expect(b.width, closeTo(f * (pill.width - 2 * inset), 1e-9));
      // Its leading end is rounded as far as it is wide (never pinched),
      // its left end follows the tube (square corners clipped by it).
      final double r = b.width / 2 < b.height / 2 ? b.width / 2 : b.height / 2;
      expect(s.body.trRadiusX, r);
      expect(s.body.brRadiusX, r);
      expect(s.body.tlRadiusX, 0);
      if (f == 1) {
        // Full: exactly the tube.
        expect(b, s.tube.outerRect);
        expect(s.body.trRadiusX, s.tube.trRadiusX);
      }
    });
  }

  // Gradient sliders (channels, white LED, temperature): the gradient is
  // inset from the track and the knob from the gradient by the same step,
  // concentric at both ends, and the knob never reaches the gradient's edge.
  const Size bar = Size(321, 44);
  const double g = GlassSlider.gradientInset;
  for (final double f in <double>[0, 0.5, 1]) {
    test('gradient knob at ${(f * 100).round()} %: inset, concentric', () {
      final (:Offset centre, :double radius) = GlassSlider.gradientKnob(bar, f);
      final double end = bar.height / 2;
      expect(centre.dy, end);
      expect(radius, end - 2 * g);
      // Inside the gradient (the track deflated by g) with g to spare.
      final Rect gradient = (Offset.zero & bar).deflate(g);
      final Rect knob = Rect.fromCircle(center: centre, radius: radius);
      expect(knob.left - gradient.left, greaterThanOrEqualTo(g - 1e-9));
      expect(gradient.right - knob.right, greaterThanOrEqualTo(g - 1e-9));
      expect(knob.top - gradient.top, closeTo(g, 1e-9));
      expect(gradient.bottom - knob.bottom, closeTo(g, 1e-9));
      // At an end it shares the track's centre of curvature.
      if (f == 0) expect(centre.dx, end);
      if (f == 1) expect(centre.dx, bar.width - end);
    });
  }
}
