import 'dart:math' as math;

import 'package:meta/meta.dart';

import '../model/channel_color.dart';
import '../model/channel_layout.dart';
import '../protocol/eb/eb_scene.dart';
import '../protocol/eb/mode_catalog.dart';
import 'color_science.dart';
import 'led_white_points.dart';
import 'light_surfaces.dart';
import 'steady_colour.dart';

/// What a light looks like to the eye: the sum of its emitters (R, G, B and
/// every white LED at its own colour temperature), at full intensity;
/// brightness is carried separately so dim lights keep their hue in the UI.
@immutable
final class DisplayColor {
  const DisplayColor(this.color, this.brightness, {this.off = false});

  /// Normalised linear colour (max channel 1), black when nothing emits.
  final LinearRgb color;

  /// 0..1 perceptual output level (master brightness).
  final double brightness;
  final bool off;

  /// [steady]: the light's colour kept steady at low channel values
  /// (used when it shows [s]'s colour).
  static DisplayColor ofScene(
    EbScene s, {
    required bool sleeping,
    LedWhitePoints whitePoints = const LedWhitePoints(),
    SteadyLevels? steady,
  }) {
    final ChannelLayout layout = s.layout;
    LinearRgb c;
    if (EbModeCatalog.usesPickedColor(s)) {
      final LinearRgb raw = LayoutPreview.whitesOnly(s.color)
          ? LayoutPreview.neutral
          : emitted(s.color, whitePoints);
      // Black stays black (the light is off), whatever hue is held.
      c = raw.max <= 1e-6
          ? raw
          : SteadyLevels.colourOf(steady, s.color, whitePoints) ?? raw;
    } else {
      // The effect makes its own colours: represent it by its accent colour,
      // shown the way this light renders colour (white temperature or
      // brightness on lights without colour LEDs).
      final LinearRgb accent = ColorScience.fromArgb(
        EbModeCatalog.byId(s.mode).gradient.first,
      );
      c = LayoutPreview.render(accent, layout, whitePoints);
    }
    return DisplayColor(
      c.normalized(),
      s.brightness / 255,
      off: sleeping || c.max <= 1e-6 || s.brightness == 0,
    );
  }

  /// The colour the app shows for [color]: each shown channel's LED at full
  /// scale, scaled by the channel value. On a light with colour LEDs only R,
  /// G and B are shown (its white LEDs never tint the colour in the app,
  /// [LayoutPreview.shows]); a white-only light shows its whites.
  static LinearRgb emitted(ChannelColor color, LedWhitePoints wp) {
    LinearRgb sum = const LinearRgb(0, 0, 0);
    for (int i = 0; i < color.layout.n; i++) {
      if (!LayoutPreview.shows(color.layout, i)) continue;
      final double level = ColorScience.levelToLinear(color[i]);
      if (level <= 0) continue;
      sum = sum + LayoutPreview.ledColour(color.layout.roles[i], wp) * level;
    }
    return sum;
  }
}

/// Dart mirror of the firmware's final render stage
/// (firmware/core/ElectroBrightCore/src/render/ChannelMap.h) for previews:
/// what coloured effect light looks like on a light's LEDs.
abstract final class LayoutPreview {
  /// A light with colour LEDs giving only white light (R, G and B at zero,
  /// a white LED on): the app shows [neutral], untinted by the whites.
  static bool whitesOnly(ChannelColor c) {
    if (!c.layout.hasColour) return false;
    bool white = false;
    for (int i = 0; i < c.layout.n; i++) {
      if (c[i] == 0) continue;
      if (shows(c.layout, i)) return false;
      white = true;
    }
    return white;
  }

  /// What the app shows for a colour light giving only white light.
  static const LinearRgb neutral = LinearRgb(1, 1, 1);

  /// Whether channel [i] of [layout] counts towards the colour the app
  /// shows: on a light with colour LEDs only R, G and B (W, CW and WW never
  /// affect the colour in the app); on a white-only light every channel.
  static bool shows(ChannelLayout layout, int i) =>
      !layout.hasColour ||
      switch (layout.roles[i]) {
        ChannelRole.r || ChannelRole.g || ChannelRole.b => true,
        _ => false,
      };

  /// Colour of one LED at full output (linear, max channel 1).
  static LinearRgb ledColour(ChannelRole role, LedWhitePoints wp) =>
      switch (role) {
        ChannelRole.r => const LinearRgb(1, 0, 0),
        ChannelRole.g => const LinearRgb(0, 1, 0),
        ChannelRole.b => const LinearRgb(0, 0, 1),
        ChannelRole.w => ColorScience.kelvinToLinear(wp.wK.toDouble()),
        ChannelRole.cw => ColorScience.kelvinToLinear(wp.cwK.toDouble()),
        ChannelRole.ww => ColorScience.kelvinToLinear(wp.wwK.toDouble()),
      };

  /// [c] (linear RGB) as the light shows it: unchanged on lights with colour
  /// LEDs; as white temperature on CCT (ChannelMap::colourToWhites); as
  /// brightness on a single white LED (ChannelMap::colourToWhite).
  static LinearRgb render(
    LinearRgb c,
    ChannelLayout layout,
    LedWhitePoints wp,
  ) {
    if (layout.hasColour) return c;
    final double level = math.max(c.r, math.max(c.g, c.b));
    if (layout.white == WhiteKind.single) {
      return ledColour(ChannelRole.w, wp) * math.min(1, level);
    }
    final (double cool, double warm) = colourToWhites(c.r, c.g, c.b);
    return ledColour(ChannelRole.cw, wp) * cool +
        ledColour(ChannelRole.ww, wp) * warm;
  }

  /// ChannelMap::colourToWhites for coloured light only (no white slots):
  /// returns the cool and warm LED levels (linear 0..1).
  static (double, double) colourToWhites(double r, double g, double b) {
    final double level = math.max(r, math.max(g, b));
    if (level <= 0) return (0, 0);
    final double rb = math.max(r, b);
    final double warmth = rb > 0 ? 0.5 + 0.5 * (r - b) / rb : 0.5;
    double cool = level * math.min(1, 2 * (1 - warmth));
    double warm = level * math.min(1, 2 * warmth);
    final double peak = math.max(cool, warm);
    if (peak > 1) {
      cool /= peak;
      warm /= peak;
    }
    return (cool, warm);
  }
}

/// A palette derived from the light's colour (plan §11 "LightTone"), in ARGB.
@immutable
final class LightTone {
  const LightTone({
    required this.dark,
    required this.canvas,
    required this.canvasDim,
    required this.glow,
    required this.glowStrength,
    required this.accent,
    required this.onAccent,
    required this.tint,
    required this.hue,
  });

  final bool dark;

  /// Three background stops, top (where the light "spills in") to bottom,
  /// for the light at full brightness.
  final List<int> canvas;

  /// The top stop for the light at its lowest brightness (the canvas blends
  /// between this and [canvas] first as the light dims).
  final int canvasDim;
  final int glow;

  /// 0..1: how strongly the glow shows (follows brightness, 0 when off).
  final double glowStrength;
  final int accent;

  /// Black or white, whichever reads best on [accent].
  final int onAccent;

  /// Glass tint (colour without alpha; the surface picks the opacity).
  final int tint;
  final double hue;

  static const double _neutralChroma = 0.03;

  /// The neutral tone for "no light" (first launch, nothing connected).
  static LightTone neutral({required bool dark}) =>
      dark ? _neutralDark : _neutralLight;
  // Derived once: the same for every screen without a light.
  static final LightTone _neutralDark = _deriveNeutral(dark: true);
  static final LightTone _neutralLight = _deriveNeutral(dark: false);
  static LightTone _deriveNeutral({required bool dark}) =>
      derive(const DisplayColor(LinearRgb(1, 1, 1), 0, off: true), dark: dark);

  static LightTone derive(DisplayColor d, {required bool dark}) {
    Oklch o = ColorScience.toOklch(d.color);
    double chroma = o.c;
    double hue = o.h;
    if (chroma < _neutralChroma) {
      // Whites take a hint of their temperature: warm amber or cool blue.
      final double k = ColorScience.estimateKelvin(d.color);
      hue = k < 4500 ? 70 : 245;
      chroma = k < 3500 || k > 6000 ? 0.02 : 0.008;
    }
    if (d.off) chroma *= 0.15; // graphite, a trace of the last hue
    o = Oklch(o.l, chroma, hue);

    Oklch stop(double l, double maxC) =>
        ColorScience.toGamut(Oklch(l, math.min(o.c, maxC), o.h));
    final double lift = d.off ? 0 : d.brightness;
    // Light: a bright field (OKLCH L 0.94–0.97) with a gentle wash of the
    // light's colour — enough variation for the glass to refract.
    final int canvasDim = dark
        ? _argb(stop(0.19, 0.11 * 0.4))
        : _argb(stop(0.95, 0.05 * 0.5));
    final List<int> canvas = dark
        ? <int>[
            _argb(stop(0.19 + 0.07 * lift, 0.11 * (0.4 + 0.6 * lift))),
            _argb(stop(0.16, 0.05)),
            _argb(stop(0.135, 0.02)),
          ]
        : <int>[
            _argb(stop(0.95 - 0.01 * lift, 0.05 * (0.5 + 0.5 * lift))),
            _argb(stop(0.965, 0.025)),
            _argb(stop(0.975, 0.012)),
          ];
    final int tint = _argb(
      ColorScience.toGamut(Oklch(dark ? 0.5 : 0.8, math.min(o.c, 0.1), o.h)),
    );
    final int accentArgb = dark
        ? _argb(
            _readableAccent(
              ColorScience.toGamut(Oklch(0.78, math.min(o.c, 0.16), o.h)),
              dark: true,
            ),
          )
        // Light: readable as text (>= 4.5:1) on what it really sits on, the
        // glass panels and the top of the canvas.
        : LightInk.deepen(
            LightInk.deepen(
              _argb(
                ColorScience.toGamut(Oklch(0.55, math.min(o.c, 0.16), o.h)),
              ),
              LightSurfaces.panelOver(tint, canvas[1]),
              4.5,
            ),
            canvas[0],
            4.5,
          );
    final LinearRgb accentLin = ColorScience.fromArgb(accentArgb);
    final int onAccent =
        ColorScience.contrast(accentLin, const LinearRgb(0, 0, 0)) >=
            ColorScience.contrast(accentLin, const LinearRgb(1, 1, 1))
        ? 0xFF000000
        : 0xFFFFFFFF;
    return LightTone(
      dark: dark,
      canvas: canvas,
      canvasDim: canvasDim,
      glow: _argb(
        ColorScience.toGamut(
          dark
              ? Oklch(0.75, math.min(o.c * 1.2, 0.2), o.h)
              // Light: a gentle wash of the light's colour, not grey, as
              // light as the hue is vivid (yellow near white, not olive).
              : Oklch(
                  (LightInk.cuspLightness(o.h) - 0.04).clamp(0.8, 0.93),
                  math.min(o.c * 1.25, 0.2),
                  o.h,
                ),
        ),
      ),
      glowStrength: d.off ? 0 : (0.25 + 0.75 * d.brightness).clamp(0.0, 1.0),
      accent: accentArgb,
      onAccent: onAccent,
      tint: tint,
      hue: o.h,
    );
  }

  /// Adjusts lightness until the accent has >= 3:1 against the canvas.
  static Oklch _readableAccent(Oklch a, {required bool dark}) {
    final LinearRgb bg = dark
        ? const LinearRgb(0.004, 0.005, 0.008)
        : const LinearRgb(0.9, 0.9, 0.92);
    Oklch x = a;
    for (int i = 0; i < 20; i++) {
      if (ColorScience.contrast(ColorScience.fromOklch(x).clamp01(), bg) >= 3) {
        break;
      }
      x = ColorScience.toGamut(x.copyWith(l: x.l + (dark ? 0.02 : -0.02)));
    }
    return x;
  }

  static int _argb(Oklch o) =>
      ColorScience.toArgb(ColorScience.fromOklch(o).clamp01());

  /// Blends two tones in OKLab (for animated transitions).
  static LightTone lerp(LightTone a, LightTone b, double t) {
    int mix(int x, int y) => _argb(
      ColorScience.lerp(
        ColorScience.toOklch(ColorScience.fromArgb(x)),
        ColorScience.toOklch(ColorScience.fromArgb(y)),
        t,
      ),
    );
    return LightTone(
      dark: t < 0.5 ? a.dark : b.dark,
      canvas: <int>[for (int i = 0; i < 3; i++) mix(a.canvas[i], b.canvas[i])],
      canvasDim: mix(a.canvasDim, b.canvasDim),
      glow: mix(a.glow, b.glow),
      glowStrength: a.glowStrength + (b.glowStrength - a.glowStrength) * t,
      accent: mix(a.accent, b.accent),
      onAccent: t < 0.5 ? a.onAccent : b.onAccent,
      tint: mix(a.tint, b.tint),
      hue: b.hue,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is LightTone &&
      other.dark == dark &&
      other.canvas[0] == canvas[0] &&
      other.canvas[1] == canvas[1] &&
      other.canvas[2] == canvas[2] &&
      other.canvasDim == canvasDim &&
      other.glow == glow &&
      other.glowStrength == glowStrength &&
      other.accent == accent &&
      other.tint == tint;

  @override
  int get hashCode => Object.hash(
    dark,
    canvas[0],
    canvas[1],
    canvas[2],
    glow,
    glowStrength,
    accent,
    tint,
  );
}
