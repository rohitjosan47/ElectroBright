import 'package:electrobright/core/color/color_science.dart';
import 'package:electrobright/core/color/colour_engine.dart';
import 'package:electrobright/core/color/hsv.dart';
import 'package:electrobright/core/color/steady_colour.dart';
import 'package:electrobright/core/model/channel_color.dart';
import 'package:electrobright/core/model/channel_layout.dart';
import 'package:electrobright/design/controls/glass_slider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/demo_app.dart';

/// The brightness pill's fill keeps the light's hue while the colour's
/// channels get small: no flicker between hues while dragging, and colour
/// changes glide instead of flashing.
void main() {
  double hue(Color c) =>
      ColorScience.toOklch(ColorScience.fromArgb(c.toARGB32())).h;
  double step(double a, double b) => (((b - a + 540) % 360) - 180).abs();

  Color fill(WidgetTester t) => t
      .widget<GlassSlider>(find.byKey(const ValueKey<String>('brightness')))
      .fill!;

  /// Long enough for the colour glide to land.
  Future<void> rest(WidgetTester t) async {
    for (int i = 0; i < 12; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
  }

  Future<DemoApp> open(WidgetTester t, {required bool dark}) async {
    t.platformDispatcher.platformBrightnessTestValue = dark
        ? Brightness.dark
        : Brightness.light;
    addTearDown(t.platformDispatcher.clearAllTestValues);
    final DemoApp d = await DemoApp.start(t);
    await d.open(t, 'Living room');
    return d;
  }

  for (final bool dark in <bool>[false, true]) {
    final String theme = dark ? 'dark' : 'light';

    testWidgets('$theme: (255,0,128) down to (1,0,0) keeps the fill steady', (
      WidgetTester t,
    ) async {
      final DemoApp d = await open(t, dark: dark);
      double? last;
      Color? held;
      for (int k = 255; k >= 1; k--) {
        final ChannelColor c = ChannelColor.rgbw(k, 0, k * 128 ~/ 255, 0);
        d.session('Living room').setColor(c);
        await rest(t);
        final Color f = fill(t);
        final double h = hue(f);
        if (last != null) {
          expect(step(last, h), lessThanOrEqualTo(3), reason: '$theme $c');
        }
        if (c.maxChannel < SteadyLevels.holdBelow * 255) {
          held ??= f;
          expect(f, held, reason: '$theme: held below the threshold, $c');
        }
        last = h;
      }
      expect(held, isNotNull);
      await DemoApp.shutDown(t);
    });

    testWidgets("$theme: a drag near the dark end shows the intent's hue", (
      WidgetTester t,
    ) async {
      final DemoApp d = await open(t, dark: dark);
      const ColourEngine engine = ColourEngine();
      double? last;
      for (double sat = 1; sat >= 0.6; sat -= 0.02) {
        final HsvIntent i = HsvIntent(Hsv(30, sat, 0.04));
        d
            .session('Living room')
            .setColor(
              engine.encode(i, ChannelLayout.rgbw),
              live: true,
              intent: i,
            );
        await rest(t);
        final double h = hue(fill(t));
        if (last != null) expect(step(last, h), lessThanOrEqualTo(1.5));
        last = h;
      }
      await DemoApp.shutDown(t);
    });
  }

  testWidgets('a colour change glides on the fill (not under Reduce Motion)', (
    WidgetTester t,
  ) async {
    final DemoApp d = await open(t, dark: false);
    d.session('Living room').setColor(ChannelColor.rgbw(255, 0, 0, 0));
    await rest(t);
    final Color red = fill(t);
    d.session('Living room').setColor(ChannelColor.rgbw(0, 0, 255, 0));
    await t.pump();
    await t.pump(const Duration(milliseconds: 16));
    final Color between = fill(t);
    await rest(t);
    final Color blue = fill(t);
    expect(between, isNot(anyOf(red, blue)));

    t.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    await t.pump();
    d.session('Living room').setColor(ChannelColor.rgbw(255, 0, 0, 0));
    await t.pump();
    await t.pump(const Duration(milliseconds: 16));
    expect(fill(t), red);
    await DemoApp.shutDown(t);
  });
}
