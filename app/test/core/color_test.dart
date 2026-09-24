import 'package:electrobright/core/color/color_science.dart';
import 'package:electrobright/core/color/light_tone.dart';
import 'package:electrobright/core/model/channel_color.dart';
import 'package:electrobright/core/model/channel_layout.dart';
import 'package:electrobright/core/protocol/eb/eb_scene.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('OKLCH round-trips sRGB colours', () {
    for (final int argb in <int>[
      0xFFFF0000,
      0xFF00FF00,
      0xFF0000FF,
      0xFF808080,
      0xFFFFA500,
    ]) {
      final LinearRgb c = ColorScience.fromArgb(argb);
      final LinearRgb back = ColorScience.fromOklch(ColorScience.toOklch(c));
      expect(ColorScience.toArgb(back), argb);
    }
  });

  test('blackbody colours are warm below 4000 K and cool above 7000 K', () {
    final LinearRgb warm = ColorScience.kelvinToLinear(2700);
    final LinearRgb cool = ColorScience.kelvinToLinear(9000);
    expect(warm.r, greaterThan(warm.b));
    expect(cool.b, greaterThan(cool.r * 0.95));
    expect(
      ColorScience.estimateKelvin(ColorScience.kelvinToLinear(3000)),
      closeTo(3000, 150),
    );
    expect(
      ColorScience.estimateKelvin(ColorScience.kelvinToLinear(6500)),
      closeTo(6500, 300),
    );
  });

  test('gamut mapping keeps lightness and hue', () {
    const Oklch wild = Oklch(0.7, 0.4, 150);
    final Oklch m = ColorScience.toGamut(wild);
    expect(ColorScience.inGamut(ColorScience.fromOklch(m)), isTrue);
    expect(m.l, 0.7);
    expect(m.h, 150);
    expect(m.c, lessThan(0.4));
  });

  test('display colour follows the scene', () {
    final EbScene red = EbScene.defaults(ChannelLayout.rgbw)
        .copyWith(color: ChannelColor.rgbw(255, 0, 0, 0));
    final DisplayColor d = DisplayColor.ofScene(red, sleeping: false);
    expect(d.color.r, 1);
    expect(d.color.g, lessThan(0.01));
    expect(DisplayColor.ofScene(red, sleeping: true).off, isTrue);
    // Rainbow ignores the picked colour: its own gradient represents it.
    final DisplayColor rainbow = DisplayColor.ofScene(
      red.copyWith(mode: 10),
      sleeping: false,
    );
    expect(ColorScience.toArgb(rainbow.color), 0xFFFF0000);
  });

  test('LightTone accents stay readable for every hue in both themes', () {
    for (int h = 0; h < 360; h += 15) {
      final LinearRgb c = ColorScience.fromOklch(
        ColorScience.toGamut(Oklch(0.7, 0.2, h.toDouble())),
      ).clamp01();
      for (final bool dark in <bool>[true, false]) {
        final LightTone t = LightTone.derive(
          DisplayColor(c.normalized(), 1),
          dark: dark,
        );
        final LinearRgb accent = ColorScience.fromArgb(t.accent);
        final LinearRgb bg = ColorScience.fromArgb(t.canvas[1]);
        expect(
          ColorScience.contrast(accent, bg),
          greaterThanOrEqualTo(2.9),
          reason: 'h=$h dark=$dark',
        );
        final LinearRgb on = ColorScience.fromArgb(t.onAccent);
        expect(
          ColorScience.contrast(accent, on),
          greaterThanOrEqualTo(4.5),
          reason: 'onAccent h=$h',
        );
      }
    }
  });

  test('an off light turns the palette graphite', () {
    final LightTone on = LightTone.derive(
      const DisplayColor(LinearRgb(0, 0, 1), 1),
      dark: true,
    );
    final LightTone off = LightTone.derive(
      const DisplayColor(LinearRgb(0, 0, 1), 1, off: true),
      dark: true,
    );
    double chroma(int argb) =>
        ColorScience.toOklch(ColorScience.fromArgb(argb)).c;
    expect(chroma(off.canvas[0]), lessThan(chroma(on.canvas[0]) * 0.5));
    expect(off.glowStrength, 0);
  });
}
