import 'package:electrobright/core/color/color_science.dart';
import 'package:electrobright/core/color/hsv.dart';
import 'package:electrobright/core/color/light_surfaces.dart';
import 'package:electrobright/core/color/light_tone.dart';
import 'package:flutter_test/flutter_test.dart';

/// Light theme contrast (policy V1), measured on what each element really
/// sits on (glass composited over the canvas), for lights of every hue,
/// three whites and a light that is off:
/// * text and functional icons: >= 4.5:1;
/// * component boundaries (the selected tile): >= 3:1 at the edge (a slider
///   fill differs from its track by colour and brightness, and its label
///   carries the value; a tab thumb is brighter glass inside its track and
///   its label carries the selection, full ink against dimmed; so their
///   edges are soft glass rims, not boundary strokes);
/// * decorative glyphs: a visibility floor of about 1.8:1.
void main() {
  final Map<String, (LinearRgb, bool)> lights = <String, (LinearRgb, bool)>{
    for (int h = 0; h < 360; h += 30)
      'hue $h': (
        ColorScience.fromOklch(
          ColorScience.toGamut(Oklch(0.7, 0.3, h.toDouble())),
        ).clamp01().normalized(),
        false,
      ),
    '2700 K': (ColorScience.kelvinToLinear(2700).normalized(), false),
    '4000 K': (ColorScience.kelvinToLinear(4000).normalized(), false),
    '6500 K': (ColorScience.kelvinToLinear(6500).normalized(), false),
    'off': (const LinearRgb(1, 1, 1), true),
  };

  int dim(int ink, int on) => LightInk.over(ink, LightSurfaces.dimAlpha, on);

  for (final MapEntry<String, (LinearRgb, bool)> e in lights.entries) {
    test('light theme contrast: ${e.key}', () {
      final (LinearRgb colour, bool off) = e.value;
      final LightTone tone = LightTone.derive(
        DisplayColor(colour, 1, off: off),
        dark: false,
      );
      final LightSurfaces s = LightSurfaces(tone);
      final int swatch = ColorScience.toArgb(colour);
      void atLeast(double ratio, int a, int b, String what) => expect(
        LightInk.contrast(a, b),
        greaterThanOrEqualTo(ratio),
        reason: '${e.key}: $what',
      );

      // Text and functional icons, full and dimmed.
      const int text = LightInk.text;
      for (final (String where, int bg) in <(String, int)>[
        ('a panel', s.panel),
        ('the canvas', s.canvasTop),
        ('the canvas middle', s.canvasMid),
        ('the pill track', s.pillTrack),
        ('a panel track', s.panelTrack),
        ('chrome glass', s.chrome),
      ]) {
        atLeast(4.5, text, bg, 'text on $where');
        atLeast(4.5, dim(text, bg), bg, 'dimmed text on $where');
      }
      atLeast(4.5, s.activeIcon, s.activeGlass, 'icon on a lit button');

      // Slider fills: ink on every part of the fill.
      for (final (String what, int c) in <(String, int)>[
        ('brightness fill', swatch),
        ('accent fill', tone.accent),
      ]) {
        final LuminousFill f = s.luminous(c);
        for (final int part in <int>[f.deep, f.base, f.bright]) {
          atLeast(4.5, f.ink, part, 'ink on the $what');
        }
      }

      // The boundary of the selected tile.
      atLeast(3, s.accentBorder, s.panel, 'selected edge vs tile');

      // Decorative glyphs: only a visibility floor.
      atLeast(
        LightSurfaces.glyphFloor,
        s.glyphOutline(swatch) ?? swatch,
        s.panel,
        'glyph shape vs tile',
      );
    });
  }

  test('no fully saturated colour of the wheel is a white', () {
    // A vivid amber sits near the 2500 K blackbody colour but is more
    // saturated than it: a colour (it used to flash as an ivory fill).
    for (double h = 0; h < 360; h += 0.5) {
      final List<int> rgb = Hsv(h, 1, 1).toRgb8();
      final LinearRgb c = LinearRgb(
        ColorScience.levelToLinear(rgb[0]),
        ColorScience.levelToLinear(rgb[1]),
        ColorScience.levelToLinear(rgb[2]),
      );
      expect(LightInk.isWhite(c), isFalse, reason: 'hue $h $rgb');
    }
  });

  test('a luminous fill moves smoothly with its colour', () {
    // Around the wheel at full value in small steps: the fill's lightness
    // never jumps (no stepped search, no flash) and every step keeps the
    // ink readable.
    final LightSurfaces s = LightSurfaces(
      LightTone.derive(
        const DisplayColor(LinearRgb(1, 1, 1), 1, off: true),
        dark: false,
      ),
    );
    double? last;
    int? lastInk;
    for (double h = 0; h < 360; h += 0.25) {
      final LinearRgb c = ColorScience.fromOklch(
        ColorScience.toGamut(Oklch(0.75, 0.3, h)),
      ).clamp01();
      final LuminousFill f = s.luminousOf(c);
      final double l = ColorScience.toOklch(ColorScience.fromArgb(f.base)).l;
      for (final int part in <int>[f.deep, f.base, f.bright]) {
        expect(LightInk.contrast(f.ink, part), greaterThanOrEqualTo(4.5));
      }
      // Where the ink changes (white on a deep colour, dark on a light one)
      // the fill may step once; anywhere else it follows the colour.
      if (last != null && lastInk == f.ink) {
        expect((l - last).abs(), lessThan(0.02), reason: 'hue $h');
      }
      last = l;
      lastInk = f.ink;
    }
  });

  test('whites are told from colours', () {
    for (final double k in <double>[2700, 3000, 4000, 5000, 6500]) {
      expect(
        LightInk.isWhite(ColorScience.kelvinToLinear(k)),
        isTrue,
        reason: '$k K',
      );
    }
    for (int h = 0; h < 360; h += 30) {
      final LinearRgb c = ColorScience.fromOklch(
        ColorScience.toGamut(Oklch(0.7, 0.3, h.toDouble())),
      ).clamp01();
      expect(LightInk.isWhite(c), isFalse, reason: 'hue $h');
    }
  });
}
