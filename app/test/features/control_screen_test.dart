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

  /// The single-white output caption is showing (its row is always there).
  bool captionShown(WidgetTester t) =>
      t
          .widget<AnimatedOpacity>(
            find.byKey(const ValueKey<String>('output-row')),
          )
          .opacity ==
      1;

  /// What the brightness pill says to accessibility ("70 %").
  String? pillValue(WidgetTester t) =>
      t.getSemantics(find.byKey(const ValueKey<String>('brightness'))).value;

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
    // the channel until the user asks. Its row is always laid out, so
    // nothing under the pill jumps when it appears.
    expect(captionShown(t), isFalse);
    final Finder tabs = find.byType(GlassSegmented<ControlTab>);
    final Rect below = t.getRect(tabs);
    d
        .session('Hallway')
        .setColor(ChannelColor(ChannelLayout.w, const <int>[128]));
    await settle(t);
    expect(captionShown(t), isTrue);
    expect(t.getRect(tabs), below);
    expect(find.text('Output 50 %'), findsOneWidget);
    expect(d.twin('Hallway').color[0], 128);
    await t.tap(find.text('Use full range'));
    await settle(t);
    expect(d.twin('Hallway').color[0], 255);
    expect(d.twin('Hallway').brightness, 128);
    expect(captionShown(t), isFalse);
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

  testWidgets('brightness to 0 turns the light off; power on restores it', (
    WidgetTester t,
  ) async {
    final SemanticsHandle semantics = t.ensureSemantics();
    final DemoApp d = await open(t, 'Hallway');
    d.session('Hallway').setBrightness(179);
    await settle(t);
    expect(pillValue(t), '70 %');
    // Drag to the far left and let go.
    await t.drag(
      find.byKey(const ValueKey<String>('brightness')),
      const Offset(-2000, 0),
    );
    // The pill stays empty while the session restores the brightness the
    // light wakes to (no pop back up).
    for (int i = 0; i < 20; i++) {
      await t.pump(const Duration(milliseconds: 100));
      expect(pillValue(t), '0 %');
    }
    expect(d.model('Hallway').sleeping, isTrue);
    expect(d.session('Hallway').status.state!.scene.brightness, 179);
    expect(find.text('0 %'), findsOneWidget);
    // Power on: back to where it was.
    await t.tap(
      find.byWidgetPredicate(
        (Widget w) => w is GlassIconButton && w.label == 'Turn on',
      ),
    );
    await settle(t);
    expect(d.model('Hallway').sleeping, isFalse);
    expect(pillValue(t), '70 %');
    expect(find.text('70 %'), findsOneWidget);
    semantics.dispose();
    await DemoApp.shutDown(t);
  });

  testWidgets('a nearly empty brightness pill is a dot, not a sliver', (
    WidgetTester t,
  ) async {
    final DemoApp d = await open(t, 'Desk strip');
    d.session('Desk strip').setBrightness(5); // 2 %
    await settle(t);
    final Finder track = find.descendant(
      of: find.byKey(const ValueKey<String>('brightness')),
      matching: find.byWidgetPredicate(
        (Widget w) =>
            w is CustomPaint &&
            w.painter.runtimeType.toString() == '_TrackPainter',
      ),
    );
    final Size size = t.getSize(track);
    final double h = size.height;
    final RRect fill = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, 0, h + 5 / 255 * (size.width - h), h),
      Radius.circular(h / 2),
    );
    expect(fill.width, greaterThanOrEqualTo(fill.height));
    expect(
      track,
      paints
        ..clipRRect()
        ..rrect(rrect: fill),
    );
    await DemoApp.shutDown(t);
  });
}
