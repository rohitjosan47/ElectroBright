import 'package:electrobright/core/color/color_science.dart';
import 'package:electrobright/core/color/colour_engine.dart';
import 'package:electrobright/core/color/hsv.dart';
import 'package:electrobright/core/color/led_white_points.dart';
import 'package:electrobright/core/color/light_tone.dart';
import 'package:electrobright/core/model/channel_color.dart';
import 'package:electrobright/core/model/channel_layout.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const ColourEngine engine = ColourEngine(); // CW 6500 K, WW 2700 K, W 4000 K

  group('tunable white (CCT, RGBCCT)', () {
    test('every CW/WW pair decodes and re-encodes within one step', () {
      int worst = 0;
      for (int cw = 0; cw <= 255; cw++) {
        for (int ww = 0; ww <= 255; ww++) {
          if (cw == 0 && ww == 0) continue;
          final ChannelColor c = ChannelColor(ChannelLayout.cct, <int>[cw, ww]);
          final ChannelColor back = engine.encode(
            engine.decode(c),
            ChannelLayout.cct,
          );
          worst = <int>[
            worst,
            (back[0] - cw).abs(),
            (back[1] - ww).abs(),
          ].reduce((int a, int b) => a > b ? a : b);
        }
      }
      expect(worst, lessThanOrEqualTo(1));
    });

    test('the LED temperatures are the ends of the range', () {
      expect(
        engine.encode(const WhiteIntent(6500, 1), ChannelLayout.cct).values,
        <int>[255, 0],
      );
      expect(
        engine.encode(const WhiteIntent(2700, 1), ChannelLayout.cct).values,
        <int>[0, 255],
      );
      // Beyond the LEDs: clamped to the nearer end.
      expect(
        engine.encode(const WhiteIntent(1900, 1), ChannelLayout.cct).values,
        <int>[0, 255],
      );
      expect(
        engine.encode(const WhiteIntent(9000, 1), ChannelLayout.cct).values,
        <int>[255, 0],
      );
      // Mired midpoint: both LEDs full.
      final double mid = 1e6 / ((1e6 / 6500 + 1e6 / 2700) / 2);
      expect(
        engine.encode(WhiteIntent(mid, 1), ChannelLayout.cct).values,
        <int>[255, 255],
      );
    });

    test('the factory default (both full) reads as about 3815 K at 100 %', () {
      final ColourIntent i = engine.decode(
        ChannelColor(ChannelLayout.cct, <int>[255, 255]),
      );
      expect(i, isA<WhiteIntent>());
      expect((i as WhiteIntent).kelvin, closeTo(3815, 5));
      expect(i.level, closeTo(1, 1e-9));
    });

    test('warmer requests shift output towards the warm LED', () {
      int prevWarm = -1;
      int prevCool = 256;
      for (double k = 6500; k >= 2700; k -= 50) {
        final ChannelColor c = engine.encode(
          WhiteIntent(k, 1),
          ChannelLayout.cct,
        );
        final double warmShare = c[1] / (c[0] + c[1]);
        expect(c[1] >= prevWarm || c[1] == 255, isTrue, reason: '$k K');
        expect(c[0] <= prevCool || c[0] == 255, isTrue, reason: '$k K');
        expect(warmShare, greaterThanOrEqualTo(0));
        prevWarm = c[1];
        prevCool = c[0];
      }
    });

    test('level scales both LEDs; black keeps the last temperature', () {
      final ChannelColor half = engine.encode(
        const WhiteIntent(2700, 0.5),
        ChannelLayout.cct,
      );
      expect(half.values, <int>[0, 128]);
      final ColourIntent black = engine.decode(
        ChannelColor.black(ChannelLayout.cct),
        hint: const WhiteIntent(3100, 0.8),
      );
      expect(black, const WhiteIntent(3100, 0));
    });

    test('RGBCCT: white uses only the white LEDs, colour only RGB', () {
      expect(
        engine.encode(const WhiteIntent(2700, 1), ChannelLayout.rgbcct).values,
        <int>[0, 0, 0, 0, 255],
      );
      expect(
        engine
            .encode(const HsvIntent(Hsv(0, 1, 1)), ChannelLayout.rgbcct)
            .values,
        <int>[255, 0, 0, 0, 0],
      );
      expect(
        engine.decode(
          ChannelColor(ChannelLayout.rgbcct, <int>[0, 0, 0, 90, 200]),
        ),
        isA<WhiteIntent>(),
      );
      expect(
        engine.decode(ChannelColor(ChannelLayout.rgbcct, <int>[9, 0, 0, 0, 0])),
        isA<HsvIntent>(),
      );
      expect(
        engine.decode(ChannelColor(ChannelLayout.rgbcct, <int>[9, 0, 0, 1, 0])),
        isA<RawIntent>(),
      );
    });

    test('whites follow calibrated LED temperatures', () {
      const ColourEngine warm = ColourEngine(
        LedWhitePoints(cwK: 5000, wwK: 2200),
      );
      expect(warm.whiteRange(ChannelLayout.cct), (min: 2200.0, max: 5000.0));
      expect(
        warm.encode(const WhiteIntent(5000, 1), ChannelLayout.cct).values,
        <int>[255, 0],
      );
    });
  });

  group('single white LED', () {
    test('RGBW: a white at the W LED\'s temperature is the W LED alone', () {
      expect(
        engine.encode(const WhiteIntent(4000, 1), ChannelLayout.rgbw).values,
        <int>[0, 0, 0, 255],
      );
      // Warmer than the LED: W plus a little red/green.
      final ChannelColor warm = engine.encode(
        const WhiteIntent(2700, 1),
        ChannelLayout.rgbw,
      );
      expect(warm[3], greaterThan(0));
      expect(warm[0], greaterThan(warm[2]));
      expect(warm.maxChannel, 255);
    });

    test('W: level is the channel; output multiplies with brightness', () {
      expect(
        engine.encode(const WhiteIntent(4000, 0.5), ChannelLayout.w).values,
        <int>[128],
      );
      expect(
        engine
            .encode(const HsvIntent(Hsv(200, 1, 0.25)), ChannelLayout.w)
            .values,
        <int>[64],
      );
      expect(ColourEngine.output(128, 255), closeTo(0.5, 0.01));
      expect(ColourEngine.output(255, 128), closeTo(0.5, 0.01));
      expect(ColourEngine.output(128, 128), closeTo(0.25, 0.01));
    });
  });

  group('colour', () {
    test('RGB and RGBW take the wheel\'s 8-bit colour; hue survives grey', () {
      const Hsv orange = Hsv(30, 1, 1);
      expect(
        engine.encode(const HsvIntent(orange), ChannelLayout.rgb).values,
        orange.toRgb8(),
      );
      expect(
        engine
            .encode(const HsvIntent(orange, white: 0.2), ChannelLayout.rgbw)
            .values,
        <int>[...orange.toRgb8(), 51],
      );
      final ColourIntent grey = engine.decode(
        ChannelColor(ChannelLayout.rgb, <int>[128, 128, 128]),
        hint: const HsvIntent(Hsv(210, 0.7, 0.9)),
      );
      expect((grey as HsvIntent).hsv.h, 210);
    });

    test('RGB can make a white of any temperature', () {
      final ChannelColor c = engine.encode(
        const WhiteIntent(2700, 1),
        ChannelLayout.rgb,
      );
      final LinearRgb lin = LinearRgb(
        ColorScience.levelToLinear(c[0]),
        ColorScience.levelToLinear(c[1]),
        ColorScience.levelToLinear(c[2]),
      );
      expect(ColorScience.estimateKelvin(lin.normalized()), closeTo(2700, 150));
    });

    test('CCT shows a colour as its nearest white', () {
      final ChannelColor red = engine.encode(
        const HsvIntent(Hsv(20, 0.9, 1)),
        ChannelLayout.cct,
      );
      expect(red[1], greaterThan(red[0])); // warm
      final ChannelColor blue = engine.encode(
        const HsvIntent(Hsv(220, 0.5, 1)),
        ChannelLayout.cct,
      );
      expect(blue[0], greaterThan(blue[1])); // cool
    });

    test('Hsv round-trips 8-bit RGB', () {
      for (final List<int> rgb in <List<int>>[
        <int>[255, 0, 0],
        <int>[12, 200, 90],
        <int>[255, 255, 255],
        <int>[0, 0, 0],
        <int>[40, 80, 250],
      ]) {
        expect(Hsv.fromRgb8(rgb[0], rgb[1], rgb[2]).toRgb8(), rgb);
      }
    });
  });

  group('previews (mirror of firmware ChannelMap.h)', () {
    test(
      'colourless lights show effect colours as white temperature or level',
      () {
        final (double cool, double warm) = LayoutPreview.colourToWhites(
          1,
          0,
          0,
        );
        expect((cool, warm), (0.0, 1.0)); // red -> warm LED
        expect(LayoutPreview.colourToWhites(0, 0, 1), (
          1.0,
          0.0,
        )); // blue -> cool
        expect(LayoutPreview.colourToWhites(0.5, 0.5, 0.5), (
          0.5,
          0.5,
        )); // white -> both
        expect(LayoutPreview.colourToWhites(0, 0.3, 0), (
          0.3,
          0.3,
        )); // green -> neutral
      },
    );

    test('display colour sums every LED at its own temperature', () {
      const LedWhitePoints wp = LedWhitePoints();
      final LinearRgb ww = DisplayColor.emitted(
        ChannelColor(ChannelLayout.cct, <int>[0, 255]),
        wp,
      );
      final LinearRgb cw = DisplayColor.emitted(
        ChannelColor(ChannelLayout.cct, <int>[255, 0]),
        wp,
      );
      expect(ww.r, greaterThan(ww.b)); // warm LED looks warm
      expect(cw.b, greaterThan(ww.b));
    });
  });
}
