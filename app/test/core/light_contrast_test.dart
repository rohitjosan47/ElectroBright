import 'package:electrobright/core/color/color_science.dart';
import 'package:electrobright/core/color/hsv.dart';
import 'package:electrobright/core/color/light_surfaces.dart';
import 'package:electrobright/core/color/light_tone.dart';
import 'package:electrobright/design/tokens/tokens.dart';
import 'package:flutter_test/flutter_test.dart';

/// Light theme contrast (policy V1), measured on what each element really
/// sits on (glass composited over the canvas), for lights of every hue,
/// three whites and a light that is off:
/// * text and functional icons: >= 4.5:1 (on a pill slider's fill, its
///   fixed ink, the same for every light);
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

  test("the pill glass's fixed ink reads on it over every light's track", () {
    // The water is transparent: it is checked as it shows over the track of
    // every light (light theme: chrome glass on the canvas; dark theme: the
    // panel glass on the canvas's top and middle stops).
    for (final MapEntry<String, (LinearRgb, bool)> e in lights.entries) {
      final (LinearRgb colour, bool off) = e.value;
      final DisplayColor d = DisplayColor(colour, 1, off: off);
      final LightSurfaces s = LightSurfaces(LightTone.derive(d, dark: false));
      final LightTone night = LightTone.derive(d, dark: true);
      for (final (bool dark, int track) in <(bool, int)>[
        (false, s.pillTrack),
        for (final int canvas in <int>[night.canvas[0], night.canvas[1]])
          (
            true,
            LightInk.over(
              LightInk.over(LightInk.white, 0.1, night.tint),
              0.16,
              canvas,
            ),
          ),
      ]) {
        final PillGlass g = PillFill.of(dark: dark);
        // Colourless water: what shows under the ink is the track itself;
        // under Reduce Transparency the solid fill.
        for (final (String on, int under) in <(String, int)>[
          ('the water', track),
          ('the solid fill', g.solid.toARGB32()),
        ]) {
          expect(
            LightInk.contrast(g.ink.toARGB32(), under),
            greaterThanOrEqualTo(4.5),
            reason: '${e.key}, ${dark ? 'dark' : 'light'}: ink on $on',
          );
        }
      }
    }
  });

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
