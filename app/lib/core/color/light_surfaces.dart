import 'dart:math' as math;

import 'package:meta/meta.dart';

import 'color_science.dart';
import 'light_tone.dart';

/// Colour arithmetic for the light theme, in ARGB as Flutter paints it:
/// translucent layers composite in gamma-encoded sRGB, contrast is WCAG's
/// (relative luminance from linear light).
abstract final class LightInk {
  /// Text and icons on light surfaces.
  static const int text = 0xFF15171C;
  static const int white = 0xFFFFFFFF;

  /// [top] at [alpha] over the opaque [bottom] (sRGB, like the renderer).
  static int over(int top, double alpha, int bottom) {
    int ch(int shift) {
      final double t = ((top >> shift) & 0xFF).toDouble();
      final double b = ((bottom >> shift) & 0xFF).toDouble();
      return (t * alpha + b * (1 - alpha)).round().clamp(0, 255);
    }

    return 0xFF000000 | ch(16) << 16 | ch(8) << 8 | ch(0);
  }

  static double contrast(int a, int b) =>
      ColorScience.contrast(ColorScience.fromArgb(a), ColorScience.fromArgb(b));

  static int argb(Oklch o) => ColorScience.toArgb(
    ColorScience.fromOklch(ColorScience.toGamut(o)).clamp01(),
  );

  static Oklch oklch(int argb) =>
      ColorScience.toOklch(ColorScience.fromArgb(argb));

  /// [colour] darkened (OKLCH lightness, hue and chroma kept in gamut) until
  /// it has at least [ratio] against [bg]. Used for fine edges and strokes,
  /// never for whole fills.
  static int deepen(int colour, int bg, double ratio) {
    Oklch o = oklch(colour);
    int c = colour;
    for (int i = 0; i < 70 && contrast(c, bg) < ratio; i++) {
      o = ColorScience.toGamut(o.copyWith(l: math.max(0, o.l - 0.012)));
      c = ColorScience.toArgb(ColorScience.fromOklch(o).clamp01());
    }
    return c;
  }

  /// Near-black text or white, whichever reads better on [bg].
  static int on(int bg) =>
      contrast(text, bg) >= contrast(white, bg) ? text : white;

  /// A white light: nearly neutral, or close to the blackbody colour of its
  /// own temperature within the white-LED range (a 2700 K white is
  /// orange-ish yet still a white).
  static bool isWhite(LinearRgb colour) {
    final LinearRgb c = colour.normalized();
    final double k = ColorScience.estimateKelvin(c).clamp(1500.0, 12000.0);
    final Oklch a = ColorScience.toOklch(c);
    final Oklch b = ColorScience.toOklch(
      ColorScience.kelvinToLinear(k).normalized(),
    );
    double x(Oklch o) => o.c * math.cos(o.h * math.pi / 180);
    double y(Oklch o) => o.c * math.sin(o.h * math.pi / 180);
    final double d = math.sqrt(
      math.pow(a.l - b.l, 2) +
          math.pow(x(a) - x(b), 2) +
          math.pow(y(a) - y(b), 2),
    );
    // Below ~2500 K a "white" is an orange (a saturated orange sits right on
    // the 2000 K blackbody colour); the app's white LEDs span 2700–6500 K.
    // A white is never more saturated than its blackbody colour (a vivid
    // amber near 2500 K is a colour).
    return a.c < 0.04 ||
        (d < 0.04 && a.c <= b.c + 0.01 && k >= 2500 && k <= 10000);
  }

  /// Warm or neutral whites (ivory) below 5000 K, cool whites above.
  static bool isWarm(LinearRgb white) =>
      ColorScience.estimateKelvin(white.normalized()) < 5000;

  /// Lightness at which [hue] reaches its most saturated in sRGB. Exact
  /// (not on a grid): it moves smoothly with the hue, so a colour dragged
  /// across hues never makes what is derived from it step back and forth.
  static double cuspLightness(double hue) {
    double chromaAt(double l) => ColorScience.toGamut(Oklch(l, 0.4, hue)).c;
    // A coarse scan finds the peak's neighbourhood; the most saturated
    // lightness is then refined (chroma rises to the cusp, then falls).
    double best = 0.6, chroma = -1;
    for (double l = 0.4; l <= 0.97; l += 0.03) {
      final double c = chromaAt(l);
      if (c > chroma) {
        chroma = c;
        best = l;
      }
    }
    double lo = math.max(0.4, best - 0.03), hi = math.min(0.97, best + 0.03);
    const double phi = 0.6180339887;
    double a = hi - phi * (hi - lo), b = lo + phi * (hi - lo);
    double ca = chromaAt(a), cb = chromaAt(b);
    for (int i = 0; i < 24; i++) {
      if (ca < cb) {
        lo = a;
        a = b;
        ca = cb;
        b = lo + phi * (hi - lo);
        cb = chromaAt(b);
      } else {
        hi = b;
        b = a;
        cb = ca;
        a = hi - phi * (hi - lo);
        ca = chromaAt(a);
      }
    }
    return (lo + hi) / 2;
  }
}

/// A slider fill that looks like light inside glass: the light's own colour,
/// deeper where it starts and brighter at its leading end, the ink that reads
/// on all of it, and the colour it casts onto the surface below. It differs
/// from the empty track by colour and brightness; its edge is a soft
/// liquid-glass highlight, not an outline.
@immutable
final class LuminousFill {
  const LuminousFill({
    required this.deep,
    required this.base,
    required this.bright,
    required this.ink,
    required this.under,
  });

  final int deep;
  final int base;
  final int bright;

  /// Text and icons on the fill (>= 4.5:1 on every part of it).
  final int ink;

  /// Coloured under-light (drawn translucent, blurred, below the fill).
  final int under;
}

/// The light theme's surfaces for one [LightTone]: what each element really
/// sits on (glass composited over the canvas), and the fills, edges and inks
/// that read on it. Widgets paint with these; the contrast test checks them.
final class LightSurfaces {
  LightSurfaces(this.tone) : assert(!tone.dark, 'light theme only');

  final LightTone tone;

  // ---- Panel glass (GlassSurface, panel tier) -------------------------------
  /// Panel fill: light, translucent, the glass tint lifted towards white.
  static const double panelTopAlpha = 0.74;
  static const double panelBottomAlpha = 0.66;
  static const double panelTopWhite = 0.84;
  static const double panelBottomWhite = 0.72;

  /// A very light hairline; the specular rim does most of the separating.
  static const int hairline = 0x0F000000;

  /// Colour of the panel fill at [white] of the way from [tint] to white.
  static int panelColour(int tint, double white) =>
      LightInk.over(LightInk.white, white, tint);

  /// A panel as it renders over the canvas's middle stop (its top half).
  static int panelOver(int tint, int canvasMid) =>
      LightInk.over(panelColour(tint, panelTopWhite), panelTopAlpha, canvasMid);

  int get canvasTop => tone.canvas[0];
  int get canvasMid => tone.canvas[1];
  int get panel => panelOver(tone.tint, canvasMid);

  // ---- Chrome glass (liquid glass: buttons, thumbs, the brightness pill) ----
  /// Untinted chrome: mostly the refracted canvas, a little white.
  static const double chromeAlpha = 0.12;
  int get chrome => LightInk.over(LightInk.white, chromeAlpha, canvasTop);

  // ---- Slider tracks ----------------------------------------------------------
  /// A faint neutral tint so the empty track reads as glass, not a hole.
  static const double trackAlpha = 0.035;
  int trackOn(int bg) => LightInk.over(0xFF000000, trackAlpha, bg);

  /// The brightness pill's track (chrome over the canvas) and a slider's
  /// track inside a panel.
  int get pillTrack => trackOn(chrome);
  int get panelTrack => trackOn(panel);

  /// The fill for a slider in [colour] (the light's colour, or the accent).
  LuminousFill luminous(int colour) =>
      luminousOf(ColorScience.fromArgb(colour));

  /// [luminous] for an unrounded colour (linear light). Continuous in the
  /// colour: a colour that moves smoothly gives a fill that does too.
  LuminousFill luminousOf(LinearRgb lin) {
    final Oklch o = ColorScience.toOklch(lin);
    final bool white = LightInk.isWhite(lin);
    final bool warm = white && LightInk.isWarm(lin);
    // Whites: a luminous ivory or a clean cool white, faintly tinted.
    final double l0 = white
        ? (warm ? 0.93 : 0.955)
        : LightInk.cuspLightness(o.h).clamp(0.5, 0.92);
    Oklch at(double lightness) => white
        ? Oklch(lightness, warm ? 0.042 : 0.02, warm ? 85 : 235)
        : ColorScience.toGamut(Oklch(lightness, 0.37, o.h));
    int deepAt(double l) => LightInk.argb(at(l - 0.05));
    int brightAt(double l) => LightInk.argb(at(math.min(0.985, l + 0.04)));
    bool reads(int ink, double l) =>
        LightInk.contrast(ink, deepAt(l)) >= 4.5 &&
        LightInk.contrast(ink, brightAt(l)) >= 4.5;
    LuminousFill fill(double l, int ink) => LuminousFill(
      deep: deepAt(l),
      base: LightInk.argb(at(l)),
      bright: brightAt(l),
      ink: ink,
      under: underLightOf(lin),
    );
    for (final int ink in <int>[LightInk.text, LightInk.white]) {
      if (reads(ink, l0)) return fill(l0, ink);
    }
    // Neither ink reads yet (a mid-tone): brighter, not darker, just as far
    // as dark text needs (found exactly, not in steps).
    const double top = 0.96;
    if (!reads(LightInk.text, top)) return fill(top, LightInk.text);
    double lo = l0, hi = top;
    for (int i = 0; i < 24; i++) {
      final double mid = (lo + hi) / 2;
      if (reads(LightInk.text, mid)) {
        hi = mid;
      } else {
        lo = mid;
      }
    }
    return fill(hi, LightInk.text);
  }

  /// Coloured light cast onto the surface below an element in [colour].
  int underLight(int colour) => underLightOf(ColorScience.fromArgb(colour));

  /// [underLight] for an unrounded colour (linear light).
  int underLightOf(LinearRgb lin) {
    if (LightInk.isWhite(lin)) {
      return LightInk.argb(
        LightInk.isWarm(lin)
            ? const Oklch(0.88, 0.07, 80)
            : const Oklch(0.9, 0.04, 235),
      );
    }
    final Oklch o = ColorScience.toOklch(lin);
    return LightInk.argb(
      Oklch(
        (LightInk.cuspLightness(o.h) - 0.04).clamp(0.8, 0.93),
        math.min(math.max(o.c, 0.12), 0.2),
        o.h,
      ),
    );
  }

  // ---- Lit buttons ------------------------------------------------------------
  /// A lit button's glass tint: the light's colour, luminous, translucent.
  static const double activeTintAlpha = 0.55;
  int get activeTint {
    final Oklch g = LightInk.oklch(tone.glow);
    // As light as the hue is vivid (a yellow tint near white, not olive).
    double l = (LightInk.cuspLightness(g.h) - 0.04).clamp(0.84, 0.94);
    int tint = LightInk.argb(Oklch(l, math.min(g.c, 0.16), g.h));
    // Keep the icon at >= 4.5:1 by lifting the tint, never by dimming it.
    for (int i = 0; i < 12; i++) {
      final int glass = activeGlassOf(tint);
      if (LightInk.contrast(LightInk.on(glass), glass) >= 4.5) break;
      l = math.min(0.97, l + 0.02);
      tint = LightInk.argb(Oklch(l, math.min(g.c, 0.16), g.h));
    }
    return tint;
  }

  int activeGlassOf(int tint) =>
      LightInk.over(tint, activeTintAlpha, canvasTop);
  int get activeGlass => activeGlassOf(activeTint);
  int get activeIcon => LightInk.on(activeGlass);

  /// The coloured under-light of lit buttons and selected tiles.
  int get glow => underLight(tone.glow);

  // ---- Inks and decorations ---------------------------------------------------
  /// Dimmed text or icons never go below this opacity on light surfaces.
  static const double dimAlpha = 0.72;

  /// [alpha] for dimmed text or icons: as is on dark, floored on light.
  static double dim(double alpha, {required bool dark}) =>
      dark ? alpha : math.max(alpha, dimAlpha);

  /// Visibility floor for decorative glyph shapes on a tile.
  static const double glyphFloor = 1.8;

  /// A fine outline for a glyph in [colour] that would not show on a tile
  /// (whites, yellows): a slightly deeper shade; null when not needed.
  int? glyphOutline(int colour) =>
      LightInk.contrast(colour, panel) >= glyphFloor
      ? null
      : LightInk.deepen(colour, panel, glyphFloor);

  /// Selected borders and focus marks (the accent, >= 3:1 on tiles).
  int get accentBorder => tone.accent;
}
