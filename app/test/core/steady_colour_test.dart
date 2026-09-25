import 'package:electrobright/core/color/color_science.dart';
import 'package:electrobright/core/color/colour_engine.dart';
import 'package:electrobright/core/color/hsv.dart';
import 'package:electrobright/core/color/led_white_points.dart';
import 'package:electrobright/core/color/light_tone.dart';
import 'package:electrobright/core/color/steady_colour.dart';
import 'package:electrobright/core/model/channel_color.dart';
import 'package:electrobright/core/model/channel_layout.dart';
import 'package:electrobright/core/protocol/eb/eb_scene.dart';
import 'package:flutter_test/flutter_test.dart';

/// The light's colour as the UI shows it stays steady when its channels are
/// too small for 8 bits to resolve the hue: a colour dimmed step by step
/// keeps its hue, and below 2 % of full scale the hue is held.
void main() {
  const LedWhitePoints wp = LedWhitePoints();

  double hue(LinearRgb c) =>
      ColorScience.toOklch(ColorScience.fromArgb(ColorScience.toArgb(c))).h;
  double step(double a, double b) => (((b - a + 540) % 360) - 180).abs();

  /// (255,0,128) down to (1,0,0) in single steps.
  List<ChannelColor> sweep(ChannelLayout layout) => <ChannelColor>[
    for (int k = 255; k >= 1; k--)
      ChannelColor(layout, <int>[
        k,
        0,
        k * 128 ~/ 255,
        ...List<int>.filled(layout.n - 3, 0),
      ]),
  ];

  bool dim(ChannelColor c) => c.maxChannel < SteadyLevels.holdBelow * 255;

  test('the cause: hues from the 8-bit channels jump at small values', () {
    double? last;
    double worst = 0;
    for (final ChannelColor c in sweep(ChannelLayout.rgb)) {
      final double h = hue(DisplayColor.emitted(c, wp).normalized());
      if (last != null && step(last, h) > worst) worst = step(last, h);
      last = h;
    }
    expect(worst, greaterThan(20));
  });

  for (final ChannelLayout layout in <ChannelLayout>[
    ChannelLayout.rgb,
    ChannelLayout.rgbw,
    ChannelLayout.rgbcct,
  ]) {
    test('${layout.wire}: a single-step sweep keeps its hue', () {
      SteadyLevels? s;
      double? last;
      double? held;
      for (final ChannelColor c in sweep(layout)) {
        s = SteadyLevels.next(s, c);
        expect(s!.source, c);
        final double h = hue(s.emitted(wp));
        if (last != null) {
          expect(step(last, h), lessThanOrEqualTo(3), reason: '$c');
        }
        if (dim(c)) {
          held ??= h;
          expect(h, held, reason: 'held below the threshold: $c');
        }
        last = h;
      }
      expect(held, isNotNull);
    });
  }

  test('a real change of colour is followed, also when dim', () {
    SteadyLevels? s = SteadyLevels.next(null, ChannelColor.rgbw(255, 0, 0, 0));
    final double red = hue(s!.emitted(wp));
    s = SteadyLevels.next(s, ChannelColor.rgbw(0, 0, 255, 0));
    expect(step(red, hue(s!.emitted(wp))), greaterThan(90));
    // Above the threshold a dim colour is read again once it no longer
    // matches: 20,0,0 -> 0,0,20 is blue.
    s = SteadyLevels.next(s, ChannelColor.rgbw(20, 0, 0, 0));
    s = SteadyLevels.next(s, ChannelColor.rgbw(0, 0, 20, 0));
    expect(s!.levels, <double>[0, 0, 1, 0]);
  });

  test('below the threshold the last hue is held, even through black', () {
    SteadyLevels? s = SteadyLevels.next(null, ChannelColor.rgbw(200, 40, 0, 0));
    final List<double> levels = s!.levels;
    for (final ChannelColor c in <ChannelColor>[
      ChannelColor.rgbw(3, 1, 0, 0),
      ChannelColor.rgbw(3, 2, 0, 0),
      ChannelColor.rgbw(0, 0, 0, 0),
      ChannelColor.rgbw(1, 0, 2, 0),
    ]) {
      s = SteadyLevels.next(s, c);
      expect(s!.levels, levels, reason: '$c');
      expect(s.source, c);
    }
    // First sight of a dim colour: its channels are all there is.
    expect(
      SteadyLevels.next(null, ChannelColor.rgbw(3, 1, 0, 0))!.levels,
      <double>[1, 1 / 3, 0, 0],
    );
  });

  test("the editor's intent gives the exact hue at any level", () {
    const ColourEngine engine = ColourEngine(wp);
    SteadyLevels? s;
    double? last;
    // A drag across the dark end of the square: hue 30, value 4 %.
    for (double sat = 1; sat >= 0.6; sat -= 0.02) {
      final HsvIntent i = HsvIntent(Hsv(30, sat, 0.04));
      final ChannelColor c = engine.encode(i, ChannelLayout.rgbw);
      s = SteadyLevels.next(
        s,
        c,
        intent: engine.fullLevels(i, ChannelLayout.rgbw),
      );
      final double h = hue(s!.emitted(wp));
      if (last != null) expect(step(last, h), lessThanOrEqualTo(1.5));
      last = h;
    }
    // Exactly the colour at full value.
    final LinearRgb full = SteadyLevels.next(
      null,
      engine.encode(const HsvIntent(Hsv(30, 1, 0.04)), ChannelLayout.rgb),
      intent: engine.fullLevels(
        const HsvIntent(Hsv(30, 1, 0.04)),
        ChannelLayout.rgb,
      ),
    )!.emitted(wp);
    final LinearRgb bright = DisplayColor.emitted(
      engine.encode(const HsvIntent(Hsv(30, 1, 1)), ChannelLayout.rgb),
      wp,
    ).normalized();
    expect(hue(full), closeTo(hue(bright), 0.5));
  });

  test('full levels of whites do not depend on the level', () {
    const ColourEngine engine = ColourEngine(wp);
    for (final ChannelLayout layout in ChannelLayout.values) {
      final List<double> a = engine.fullLevels(
        const WhiteIntent(3000, 0.01),
        layout,
      )!;
      final List<double> b = engine.fullLevels(
        const WhiteIntent(3000, 1),
        layout,
      )!;
      expect(a, b, reason: layout.wire);
    }
    expect(
      engine.fullLevels(
        RawIntent(ChannelColor.rgbw(1, 2, 3, 4)),
        ChannelLayout.rgbw,
      ),
      isNull,
    );
  });

  test('a black light stays off whatever hue is held', () {
    final SteadyLevels? s = SteadyLevels.next(
      SteadyLevels.next(null, ChannelColor.rgbw(255, 0, 0, 0)),
      ChannelColor.rgbw(0, 0, 0, 0),
    );
    final EbScene scene = EbScene.defaults(ChannelLayout.rgbw)
        .copyWith(color: ChannelColor.rgbw(0, 0, 0, 0));
    final DisplayColor d = DisplayColor.ofScene(
      scene,
      sleeping: false,
      steady: s,
    );
    expect(d.off, isTrue);
  });

  test('HSV to RGB: 8-bit values are the rounded unquantised ones', () {
    for (double h = 0; h < 360; h += 7) {
      for (final double v in <double>[0.01, 0.3, 1]) {
        final Hsv c = Hsv(h, 0.8, v);
        expect(c.toRgb8(), <int>[
          for (final double x in c.toRgb()) (x * 255).round(),
        ]);
      }
    }
  });
}
