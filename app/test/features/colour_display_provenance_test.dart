import 'dart:async';
import 'dart:math' as math;

import 'package:electrobright/app/providers.dart';
import 'package:electrobright/core/color/color_science.dart';
import 'package:electrobright/core/color/colour_engine.dart';
import 'package:electrobright/core/color/led_white_points.dart';
import 'package:electrobright/core/model/channel_color.dart';
import 'package:electrobright/core/model/channel_layout.dart';
import 'package:electrobright/core/protocol/eb/eb_frame.dart';
import 'package:electrobright/design/components/glass_controls.dart';
import 'package:electrobright/design/controls/glass_slider.dart';
import 'package:electrobright/design/controls/hue_wheel.dart';
import 'package:electrobright/design/tone/screen_colour.dart';
import 'package:electrobright/drivers/electrobright/eb_session.dart';
import 'package:electrobright/drivers/electrobright/eb_types.dart';
import 'package:electrobright/features/control/colour/colour_editor.dart';
import 'package:electrobright/features/control/control_screen.dart';
import 'package:electrobright/sessions/fixture_session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/demo_app.dart';

/// What the screen shows as the light's colour follows where the colour came
/// from, not how close two values are: while the user's pick is the newest
/// change, exactly that pick (the light's paced echoes lag the finger); a
/// change from the light (preset load, another client) switches to the
/// light's channels.
void main() {
  const String room = 'Living room';
  const ColourEngine engine = ColourEngine();

  double hue(LinearRgb c) => ColorScience.toOklch(c).h;
  double delta(double a, double b) => ((b - a + 540) % 360) - 180;

  /// The colour of channel levels (0..1 per R, G, B) on the light, at full.
  LinearRgb ofLevels(double r, double g, double b) => LinearRgb(
    math.pow(r, 2.2).toDouble(),
    math.pow(g, 2.2).toDouble(),
    math.pow(b, 2.2).toDouble(),
  ).normalized();
  LinearRgb ofHsv(Hsv h) {
    final List<double> rgb = h.toRgb();
    return ofLevels(rgb[0], rgb[1], rgb[2]);
  }

  ProviderContainer container(WidgetTester t) =>
      ProviderScope.containerOf(t.element(find.byType(ControlScreen)));
  FixtureStatus status(WidgetTester t) =>
      container(t).read(fixtureStatusProvider(DemoApp.idOf(room)));

  /// The colour the display glides to.
  LinearRgb target(WidgetTester t) => linearOf(
    swatchOf(
      status(t).state!.scene.color,
      const LedWhitePoints(),
      steady: container(t).read(steadyLevelsProvider(DemoApp.idOf(room))),
    ),
  );

  /// The orb's colour as shown (gliding, or following the finger).
  LinearRgb orb(WidgetTester t) =>
      linearOf(t.widget<LightOrb>(find.byType(LightOrb)).color);

  Future<DemoApp> open(WidgetTester t, {required bool dark}) async {
    t.view.physicalSize = const Size(393 * 3, 1600 * 3);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    t.platformDispatcher.platformBrightnessTestValue = dark
        ? Brightness.dark
        : Brightness.light;
    addTearDown(t.platformDispatcher.clearAllTestValues);
    final DemoApp d = await DemoApp.start(t);
    await d.open(t, room);
    return d;
  }

  /// The orb shows [want] exactly.
  void shows(WidgetTester t, LinearRgb want, {required String at}) {
    final LinearRgb shown = orb(t);
    final LinearRgb aim = target(t);
    for (final (double a, double b) in <(double, double)>[
      (shown.r, aim.r),
      (shown.g, aim.g),
      (shown.b, aim.b),
    ]) {
      expect(a, closeTo(b, 1e-6), reason: '$at: shown as the finger');
    }
    expect(delta(hue(want), hue(shown)).abs(), lessThan(1e-6), reason: at);
  }

  /// A drag: [steps] finger positions, one per 16 ms frame (the light's
  /// echoes lag: frames are paced at 25 ms and the light ticks every 50 ms),
  /// then 40 frames after release. Checks every frame: the display's target
  /// is the finger's exact colour and, while the finger is down, the orb
  /// shows exactly that colour (no glide, no lag); after release it stays on
  /// it.
  Future<void> drag(
    WidgetTester t,
    DemoApp d, {
    required List<Offset> path,
    required List<LinearRgb> finger,
  }) async {
    final TestGesture g = await t.startGesture(path.first);
    await t.pump(const Duration(milliseconds: 16));
    bool lagged = false;
    for (int i = 1; i < path.length; i++) {
      await g.moveTo(path[i]);
      await t.pump(const Duration(milliseconds: 16));
      final double want = hue(finger[i]);
      expect(
        delta(want, hue(target(t))).abs(),
        lessThan(1e-6),
        reason: 'frame $i: the target is the finger',
      );
      shows(t, finger[i], at: 'frame $i');
      lagged |= d.twin(room).color != status(t).state!.scene.color;
    }
    final LinearRgb last = finger.last;
    await g.up();
    for (int i = 0; i < 40; i++) {
      await t.pump(const Duration(milliseconds: 16));
      // Released and confirmed: still exactly the pick, shown as it is.
      expect(delta(hue(last), hue(target(t))).abs(), lessThan(1e-6));
      shows(t, last, at: 'released, frame $i');
    }
    expect(lagged, isTrue, reason: 'the light lagged the finger');
    expect(d.twin(room).color, status(t).state!.scene.color);
  }

  for (final bool dark in <bool>[false, true]) {
    final String theme = dark ? 'dark' : 'light';

    testWidgets('$theme: the wheel ring at full value', (WidgetTester t) async {
      final DemoApp d = await open(t, dark: dark);
      d.session(room).setColor(ChannelColor.rgbw(255, 0, 0, 0));
      await DemoApp.settle(t, 1);
      final Rect r = t.getRect(find.byType(HueWheel));
      final double size = math.min(r.width, 300);
      final double mid = size / 2 - 8 - size * 0.095 / 2;
      Offset at(double deg) =>
          r.center +
          Offset(math.cos(deg * math.pi / 180), math.sin(deg * math.pi / 180)) *
              mid;
      await drag(
        t,
        d,
        path: <Offset>[for (int i = 0; i <= 90; i++) at(i.toDouble())],
        finger: <LinearRgb>[
          for (int i = 0; i <= 90; i++) ofHsv(Hsv(i.toDouble(), 1, 1)),
        ],
      );
      await DemoApp.shutDown(t);
    });

    testWidgets('$theme: the S/V square, upper area', (WidgetTester t) async {
      final DemoApp d = await open(t, dark: dark);
      d.session(room).setColor(ChannelColor.rgbw(255, 64, 0, 0));
      await DemoApp.settle(t, 1);
      final Hsv start = Hsv.fromRgb8(255, 64, 0);
      final Rect r = t.getRect(find.byType(HueWheel));
      final double size = math.min(r.width, 300);
      final double rIn = size / 2 - 8 - size * 0.095;
      final double half = (rIn - 10) / math.sqrt2;
      // Value 0.9, saturation 1 -> 0.3.
      Offset at(double s) =>
          r.center + Offset(-half + 2 * half * s, -half + 2 * half * 0.1);
      await drag(
        t,
        d,
        path: <Offset>[for (int i = 0; i <= 70; i++) at(1 - i * 0.01)],
        finger: <LinearRgb>[
          for (int i = 0; i <= 70; i++) ofHsv(Hsv(start.h, 1 - i * 0.01, 0.9)),
        ],
      );
      await DemoApp.shutDown(t);
    });

    testWidgets('$theme: a channel slider from 150 to 255', (
      WidgetTester t,
    ) async {
      final DemoApp d = await open(t, dark: dark);
      d.session(room).setColor(ChannelColor.rgbw(150, 90, 200, 0));
      await DemoApp.settle(t, 1);
      await t.tap(find.text('Channels'));
      await DemoApp.settle(t, 2);
      final Rect r = t.getRect(
        find.byWidgetPredicate(
          (Widget w) => w is GlassSlider && w.semanticLabel == 'Red',
        ),
      );
      Offset at(int v) => Offset(r.left + r.width * v / 255, r.center.dy);
      await drag(
        t,
        d,
        path: <Offset>[
          at(150) - const Offset(30, 0),
          for (int v = 150; v <= 255; v++) at(v),
        ],
        // The slider takes the drag once past its slop, at 150.
        finger: <LinearRgb>[
          ofLevels(150 / 255, 90 / 255, 200 / 255),
          for (int v = 150; v <= 255; v++)
            ofLevels(v / 255, 90 / 255, 200 / 255),
        ],
      );
      await DemoApp.shutDown(t);
    });
  }

  testWidgets('a preset load while idle shows the light\'s colour', (
    WidgetTester t,
  ) async {
    final DemoApp d = await open(t, dark: false);
    // A preset holding orange.
    final ChannelColor orange = ChannelColor.rgbw(255, 120, 0, 0);
    d.session(room).setColor(orange);
    await DemoApp.settle(t, 1);
    expect((await d.session(room).presetSave(3)).result.outcome, EbOutcome.ok);
    await DemoApp.settle(t, 1);
    const HsvIntent pick = HsvIntent(Hsv(200, 0.7, 0.8));
    final ChannelColor picked = engine.encode(pick, ChannelLayout.rgbw);
    d.session(room).setColor(picked, intent: pick);
    await DemoApp.settle(t, 1);
    expect(status(t).view!.colorOrigin.byUser, isTrue);
    expect(delta(hue(ofHsv(pick.hsv)), hue(target(t))).abs(), lessThan(1e-6));

    expect((await d.session(room).presetLoad(3)).result.outcome, EbOutcome.ok);
    await DemoApp.settle(t, 2);
    final ChannelColor loaded = status(t).state!.scene.color;
    expect(loaded, orange);
    expect(status(t).view!.colorOrigin.byUser, isFalse);
    // The light's channels, as they are.
    final int top = loaded.maxChannel;
    expect(
      container(t).read(steadyLevelsProvider(DemoApp.idOf(room)))!.levels,
      <double>[for (final int v in loaded.values) v / top],
    );
    await DemoApp.shutDown(t);
  });

  testWidgets('a colour set by another client is shown once heard of', (
    WidgetTester t,
  ) async {
    final DemoApp d = await open(t, dark: false);
    const HsvIntent pick = HsvIntent(Hsv(120, 1, 1));
    d
        .session(room)
        .setColor(engine.encode(pick, ChannelLayout.rgbw), intent: pick);
    await DemoApp.settle(t, 1);
    expect(status(t).view!.colorOrigin.byUser, isTrue);
    // While this phone is away (the light takes one connection at a time),
    // someone else sets orange; the app hears of it when it reconnects.
    final String sim = DemoApp.lights[room]!.$1;
    d.radio.setAvailable(sim, available: false);
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await DemoApp.settle(t, 1);
    final ChannelColor other = ChannelColor.rgbw(255, 120, 0, 0);
    d.model(room)
      ..connect()
      ..write(EbFrame.encode(200, other, 255))
      ..pass()
      ..disconnect();
    expect(d.twin(room).color, other);
    d.radio.setAvailable(sim, available: true);
    for (int i = 0; i < 20 && !status(t).isReady; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await DemoApp.settle(t, 1);
    }
    await DemoApp.settle(t, 1);
    expect(status(t).isReady, isTrue);
    expect(status(t).state!.scene.color, other);
    expect(status(t).view!.colorOrigin.byUser, isFalse);
    expect(
      delta(hue(ofLevels(1, 120 / 255, 0)), hue(target(t))).abs(),
      lessThan(1e-6),
    );
    await DemoApp.shutDown(t);
  });

  testWidgets('a report with an older sequence mid-drag is ignored', (
    WidgetTester t,
  ) async {
    final DemoApp d = await open(t, dark: false);
    d.session(room).setColor(ChannelColor.rgbw(255, 0, 0, 0));
    await DemoApp.settle(t, 1);
    final Rect r = t.getRect(find.byType(HueWheel));
    final double size = math.min(r.width, 300);
    final double mid = size / 2 - 8 - size * 0.095 / 2;
    Offset at(double deg) =>
        r.center +
        Offset(math.cos(deg * math.pi / 180), math.sin(deg * math.pi / 180)) *
            mid;
    final EbSession s = d.session(room).session!;
    final TestGesture g = await t.startGesture(at(0));
    await t.pump(const Duration(milliseconds: 16));
    bool older = false;
    for (int i = 1; i <= 60; i++) {
      await g.moveTo(at(i.toDouble()));
      // Mid-drag the light is asked for its state: its STATUS reflects an
      // older frame than the finger's newest pick.
      if (i == 20) unawaited(s.resync());
      await t.pump(const Duration(milliseconds: 16));
      older |= s.confirmed.scene.color != status(t).state!.scene.color;
      expect(status(t).view!.colorOrigin.byUser, isTrue);
      expect(
        delta(hue(ofHsv(Hsv(i.toDouble(), 1, 1))), hue(target(t))).abs(),
        lessThan(1e-6),
        reason: 'frame $i',
      );
    }
    expect(s.resyncs, greaterThan(0));
    expect(older, isTrue, reason: 'the light reported older colours');
    await g.up();
    await DemoApp.settle(t, 1);
    await DemoApp.shutDown(t);
  });

  testWidgets('a colour change not from a finger glides on the orb', (
    WidgetTester t,
  ) async {
    final DemoApp d = await open(t, dark: false);
    Future<void> rest() async {
      for (int i = 0; i < 12; i++) {
        await t.pump(const Duration(milliseconds: 100));
      }
    }

    d.session(room).setColor(ChannelColor.rgbw(255, 0, 0, 0));
    await rest();
    final LinearRgb red = orb(t);
    d.session(room).setColor(ChannelColor.rgbw(0, 0, 255, 0));
    await t.pump();
    await t.pump(const Duration(milliseconds: 16));
    final LinearRgb between = orb(t);
    await rest();
    final LinearRgb blue = orb(t);
    expect(hue(between), isNot(anyOf(hue(red), hue(blue))));
    expect(delta(hue(blue), hue(target(t))).abs(), lessThan(1e-6));

    // Under Reduce Motion it changes at once.
    t.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    await t.pump();
    d.session(room).setColor(ChannelColor.rgbw(255, 0, 0, 0));
    await t.pump();
    await t.pump(const Duration(milliseconds: 16));
    expect(delta(hue(red), hue(orb(t))).abs(), lessThan(1e-6));
    await DemoApp.shutDown(t);
  });
}
