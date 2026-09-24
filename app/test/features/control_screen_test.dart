import 'package:electrobright/core/model/channel_color.dart';
import 'package:electrobright/core/model/channel_layout.dart';
import 'package:electrobright/design/components/glass_controls.dart';
import 'package:electrobright/design/controls/glass_slider.dart';
import 'package:electrobright/design/controls/hue_wheel.dart';
import 'package:electrobright/features/control/colour/colour_editor.dart';
import 'package:electrobright/features/control/control_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/demo_app.dart';

/// The control screen follows what each light can do: one demo light of
/// every fixture type, opened from Home, checked against the twin's state.
void main() {
  /// A tab of the control screen (not the type badge's words).
  Finder tab(String name) => find.descendant(
    of: find.byType(GlassSegmented<ControlTab>),
    matching: find.text(name),
  );

  /// A slider by its accessibility label.
  Finder slider(String label) => find.byWidgetPredicate(
    (Widget w) => w is GlassSlider && w.semanticLabel == label,
  );

  Future<void> settle(WidgetTester t, [int seconds = 2]) =>
      DemoApp.settle(t, seconds);

  Future<DemoApp> open(WidgetTester t, String name) async {
    t.view.physicalSize = const Size(1179, 6000);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    final DemoApp demo = await DemoApp.start(t);
    await demo.open(t, name);
    return demo;
  }

  testWidgets('single white: intensity only, 12 effects, full range', (
    WidgetTester t,
  ) async {
    final DemoApp d = await open(t, 'Hallway');
    // No colour or white tab: the pill is the light's intensity.
    expect(tab('Colour'), findsNothing);
    expect(tab('White'), findsNothing);
    expect(slider('Intensity'), findsOneWidget);
    expect(find.byType(HueWheel), findsNothing);
    // Effects: every mode except Rainbow, and why.
    expect(find.byKey(const ValueKey<String>('mode-10')), findsNothing);
    for (final int m in <int>[1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 12, 13]) {
      expect(find.byKey(ValueKey<String>('mode-$m')), findsOneWidget);
    }
    expect(
      find.text("Rainbow isn't available on single-white lights."),
      findsOneWidget,
    );
    // Channel at half: the caption shows the real output; nothing rewrites
    // the channel until the user asks.
    expect(find.byKey(const ValueKey<String>('output-caption')), findsNothing);
    d
        .session('Hallway')
        .setColor(ChannelColor(ChannelLayout.w, const <int>[128]));
    await settle(t);
    expect(find.text('Output 50 %'), findsOneWidget);
    expect(d.twin('Hallway').color[0], 128);
    await t.tap(find.text('Use full range'));
    await settle(t);
    expect(d.twin('Hallway').color[0], 255);
    expect(d.twin('Hallway').brightness, 128);
    expect(find.byKey(const ValueKey<String>('output-caption')), findsNothing);
    await DemoApp.shutDown(t);
  });

  testWidgets('tunable white: temperature, level and white chips', (
    WidgetTester t,
  ) async {
    final DemoApp d = await open(t, 'Kitchen');
    expect(tab('White'), findsOneWidget);
    expect(tab('Colour'), findsNothing);
    expect(find.byType(HueWheel), findsNothing);
    expect(slider('Colour temperature'), findsOneWidget);
    expect(slider('Level'), findsOneWidget);
    // Candle is warmer than the LEDs can go: shown at the warm end.
    expect(find.text('Candle ≈ 2700 K'), findsOneWidget);
    await t.tap(find.text('Warm 2700 K'));
    await settle(t);
    expect(d.twin('Kitchen').color.values, <int>[0, 255]); // CW, WW
    await t.tap(find.text('Daylight 6500 K'));
    await settle(t);
    expect(d.twin('Kitchen').color.values, <int>[255, 0]);
    // Effects in its own words.
    await t.tap(tab('Effects'));
    await settle(t, 1);
    expect(find.text('Temperature sweep'), findsOneWidget);
    expect(find.text('Rainbow'), findsNothing);
    await DemoApp.shutDown(t);
  });

  testWidgets('RGB: the colour wheel and three channels, no white LED', (
    WidgetTester t,
  ) async {
    final DemoApp d = await open(t, 'Desk strip');
    expect(tab('Colour'), findsOneWidget);
    expect(find.byType(HueWheel), findsOneWidget);
    expect(slider('White LED'), findsNothing);
    await t.tap(find.text('Channels'));
    await settle(t, 1);
    for (final String c in <String>['Red', 'Green', 'Blue']) {
      expect(slider(c), findsOneWidget, reason: c);
    }
    expect(slider('White'), findsNothing);
    // A white chip is made from RGB.
    await t.tap(find.text('Neutral 4000 K'));
    await settle(t);
    final ChannelColor c = d.twin('Desk strip').color;
    expect(c.values.reduce((int a, int b) => a < b ? a : b), greaterThan(150));
    await t.tap(tab('Effects'));
    await settle(t, 1);
    expect(find.text('Rainbow'), findsOneWidget);
    await DemoApp.shutDown(t);
  });

  testWidgets('RGBW: the wheel plus the white LED', (WidgetTester t) async {
    await open(t, 'Living room');
    expect(find.byType(HueWheel), findsOneWidget);
    expect(slider('White LED'), findsOneWidget);
    await t.tap(find.text('Channels'));
    await settle(t, 1);
    for (final String c in <String>['Red', 'Green', 'Blue', 'White']) {
      expect(slider(c), findsOneWidget, reason: c);
    }
    await DemoApp.shutDown(t);
  });

  testWidgets('RGB + CCT: colour or tunable white, switched explicitly', (
    WidgetTester t,
  ) async {
    final DemoApp d = await open(t, 'Bedroom');
    // The factory look (both whites) is a white: the White side is shown.
    expect(slider('Colour temperature'), findsOneWidget);
    expect(find.byType(HueWheel), findsNothing);
    await t.tap(find.text('Warm 2700 K'));
    await settle(t);
    expect(d.twin('Bedroom').color.values, <int>[0, 0, 0, 0, 255]);
    // Colour: the whites go to zero.
    await t.tap(
      find.descendant(
        of: find.byType(ColourEditor),
        matching: find.text('Colour'),
      ),
    );
    await settle(t);
    expect(find.byType(HueWheel), findsOneWidget);
    final ChannelColor c = d.twin('Bedroom').color;
    expect(c.values.sublist(3), <int>[0, 0]);
    expect(c.values.sublist(0, 3).any((int v) => v > 0), isTrue);
    await DemoApp.shutDown(t);
  });

  testWidgets('an unavailable light shows its last look with a note', (
    WidgetTester t,
  ) async {
    final DemoApp d = await open(t, 'Desk strip');
    expect(find.byKey(const ValueKey<String>('offline-note')), findsNothing);
    d.radio.setAvailable('demo-rgb', available: false);
    // Tearing the session down needs real async time (as at shutdown).
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await settle(t);
    expect(find.byKey(const ValueKey<String>('offline-note')), findsOneWidget);
    expect(find.byType(HueWheel), findsOneWidget);
    await DemoApp.shutDown(t);
  });
}
