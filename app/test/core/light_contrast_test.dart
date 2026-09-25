import 'package:electrobright/core/color/color_science.dart';
import 'package:electrobright/core/color/light_surfaces.dart';
import 'package:electrobright/core/color/light_tone.dart';
import 'package:flutter_test/flutter_test.dart';

/// Light theme contrast (policy V1), measured on what each element really
/// sits on (glass composited over the canvas), for lights of every hue,
/// three whites and a light that is off:
/// * text and functional icons: >= 4.5:1;
/// * component boundaries (fill edge, selected tile, tab thumb): >= 3:1 at
///   the edge;
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

      // Slider fills: ink on every part of the fill; the edge is the
      // boundary against both kinds of track.
      for (final (String what, int c) in <(String, int)>[
        ('brightness fill', swatch),
        ('accent fill', tone.accent),
      ]) {
        final LuminousFill f = s.luminous(c);
        for (final int part in <int>[f.deep, f.base, f.bright]) {
          atLeast(4.5, f.ink, part, 'ink on the $what');
        }
        atLeast(3, f.edge, s.pillTrack, '$what edge vs pill track');
        atLeast(3, f.edge, s.panelTrack, '$what edge vs panel track');
      }

      // Boundaries of the selected tile and the tab thumb.
      atLeast(3, s.accentBorder, s.panel, 'selected edge vs tile');
      atLeast(3, tone.accent, s.panelTrack, 'tab thumb edge vs its track');

      // Decorative glyphs: only a visibility floor.
      atLeast(
        LightSurfaces.glyphFloor,
        s.glyphOutline(swatch) ?? swatch,
        s.panel,
        'glyph shape vs tile',
      );
    });
  }

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
