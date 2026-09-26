import 'dart:async';

import 'package:electrobright/app/providers.dart';
import 'package:electrobright/core/color/colour_engine.dart';
import 'package:electrobright/core/model/channel_color.dart';
import 'package:electrobright/core/model/channel_layout.dart';
import 'package:electrobright/design/controls/glass_slider.dart';
import 'package:electrobright/design/controls/hue_wheel.dart';
import 'package:electrobright/features/all_lights/all_lights_screen.dart';
import 'package:electrobright/features/control/colour/colour_editor.dart';
import 'package:electrobright/features/control/control_screen.dart';
import 'package:electrobright/sessions/group_capabilities.dart';
import 'package:electrobright/sessions/group_session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/demo_app.dart';

/// The All Lights panel adapts to the mix of lights: the colour tab, the
/// editor's controls, which lights each control reaches; and each light's
/// level, own settings and way back.
void main() {
  const Map<String, (String, ChannelLayout)> wOnly =
      <String, (String, ChannelLayout)>{
        'Hallway': ('demo-w', ChannelLayout.w),
        'Porch': ('demo-w-2', ChannelLayout.w),
      };
  const Map<String, (String, ChannelLayout)> cctW =
      <String, (String, ChannelLayout)>{
        'Kitchen': ('demo-cct', ChannelLayout.cct),
        'Hallway': ('demo-w', ChannelLayout.w),
      };
  const Map<String, (String, ChannelLayout)> rgbW =
      <String, (String, ChannelLayout)>{
        'Desk strip': ('demo-rgb', ChannelLayout.rgb),
        'Hallway': ('demo-w', ChannelLayout.w),
      };
  const Map<String, (String, ChannelLayout)> rgbRgbwW =
      <String, (String, ChannelLayout)>{
        'Desk strip': ('demo-rgb', ChannelLayout.rgb),
        'Living room': ('demo-rgbw', ChannelLayout.rgbw),
        'Hallway': ('demo-w', ChannelLayout.w),
      };

  Future<DemoApp> open(
    WidgetTester t,
    Map<String, (String, ChannelLayout)> lights, {
    bool connect = true,
  }) async {
    t.view.physicalSize = const Size(393, 2600);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final DemoApp d = await DemoApp.start(t, lights: lights);
    await DemoApp.settle(t, 1);
    if (!connect) {
      for (final (String dev, ChannelLayout _) in lights.values) {
        d.radio.setAvailable(dev, available: false);
      }
      d.radio.setAvailable('demo-legacy', available: false);
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await DemoApp.settle(t, 2);
    }
    unawaited(
      t
          .state<NavigatorState>(find.byType(Navigator).first)
          .push(
            MaterialPageRoute<void>(builder: (_) => const AllLightsScreen()),
          ),
    );
    await DemoApp.settle(t, 5);
    expect(find.byType(AllLightsScreen), findsOneWidget);
    return d;
  }

  ProviderContainer container(WidgetTester t) =>
      ProviderScope.containerOf(t.element(find.byType(AllLightsScreen)));
  GroupSession groupOf(WidgetTester t) =>
      container(t).read(groupSessionProvider)!;

  Finder slider(String label) => find.byWidgetPredicate(
    (Widget w) => w is GlassSlider && w.semanticLabel == label,
  );
  final Finder tabs = find.byWidgetPredicate(
    (Widget w) => w.runtimeType.toString() == 'GlassSegmented<_GroupTab>',
  );

  testWidgets('only single whites: no colour tab and no tab switcher', (
    WidgetTester t,
  ) async {
    await open(t, wOnly);
    expect(find.text('2 of 2 connected'), findsOneWidget);
    expect(tabs, findsNothing);
    expect(find.byType(ColourEditor), findsNothing);
    expect(find.byKey(const ValueKey<String>('effects-grid')), findsOneWidget);
    await DemoApp.shutDown(t);
  });

  testWidgets('tunable + single white: a White tab, temperature and a match '
      'marker for the single white', (WidgetTester t) async {
    final DemoApp d = await open(t, cctW);
    expect(
      find.descendant(of: tabs, matching: find.text('White')),
      findsOneWidget,
    );
    expect(find.byType(HueWheel), findsNothing);
    expect(slider('Colour temperature'), findsOneWidget);
    expect(find.text('Temperature · 1 of 2 lights'), findsOneWidget);
    expect(find.text('1 white light keeps its white'), findsOneWidget);
    final ChannelColor hallway = d.twin('Hallway').color;
    await t.tap(find.text('Match W lights · 4000 K'));
    await DemoApp.settle(t, 1);
    final ColourIntent pick = d.session('Kitchen').status.colourPick!.intent;
    expect(pick, isA<WhiteIntent>());
    expect((pick as WhiteIntent).kelvin, 4000);
    expect(
      d.twin('Kitchen').color,
      ColourEngine(d.app.registry.byId(d.id('Kitchen'))!.whitePoints)
          .encode(pick, ChannelLayout.cct),
    );
    expect(d.twin('Hallway').color, hallway);
    await DemoApp.shutDown(t);
  });

  testWidgets('colour + single white: the wheel alone, for one of two', (
    WidgetTester t,
  ) async {
    await open(t, rgbW);
    expect(
      find.descendant(of: tabs, matching: find.text('Colour')),
      findsOneWidget,
    );
    expect(find.byType(HueWheel), findsOneWidget);
    expect(slider('White LED'), findsNothing);
    expect(slider('Colour temperature'), findsNothing);
    expect(find.text('Colour · 1 of 2 lights'), findsOneWidget);
    expect(find.text('1 white light keeps its white'), findsOneWidget);
    expect(find.textContaining('Match W lights'), findsNothing);
    await DemoApp.shutDown(t);
  });

  testWidgets('RGB + RGBW + W: the wheel and the white LED, each scoped', (
    WidgetTester t,
  ) async {
    await open(t, rgbRgbwW);
    expect(find.byType(HueWheel), findsOneWidget);
    expect(slider('White LED'), findsOneWidget);
    expect(find.text('Colour · 2 of 3 lights'), findsOneWidget);
    expect(find.text('White LED · 1 of 3'), findsOneWidget);
    expect(find.text('1 white light keeps its white'), findsOneWidget);
    await DemoApp.shutDown(t);
  });

  testWidgets('all five types: colour and white, scopes, marker and the '
      'lights at their limit', (WidgetTester t) async {
    await open(t, DemoApp.lights);
    expect(find.text('Colour · 3 of 5 lights'), findsOneWidget);
    expect(find.text('Temperature · 4 of 5 lights'), findsOneWidget);
    expect(find.text('1 white light keeps its white'), findsOneWidget);
    // A temperature below the tunable lights' warm LEDs.
    final ColourEditor editor = t.widget<ColourEditor>(
      find.byType(ColourEditor),
    );
    const WhiteIntent candle = WhiteIntent(2000, 1);
    editor.onChanged(
      const ColourEngine().encode(candle, ChannelLayout.rgbcct),
      live: false,
      intent: candle,
    );
    await DemoApp.settle(t, 1);
    final GroupCapabilities caps = container(t).read(groupCapabilitiesProvider);
    final int n = caps.limitedCount(2000);
    expect(n, greaterThan(0));
    expect(
      find.text(n == 1 ? '1 light at its limit' : '$n lights at their limit'),
      findsOneWidget,
    );
    // The white side, with the single white's temperature to match.
    expect(slider('Colour temperature'), findsOneWidget);
    expect(find.text('Match W lights · 4000 K'), findsOneWidget);
    await DemoApp.shutDown(t);
  });

  testWidgets('a light\'s level in the group changes only that light', (
    WidgetTester t,
  ) async {
    final DemoApp d = await open(t, DemoApp.groupLights);
    final int twinBefore = d.twin('Reading lamp').brightness;
    final Finder row = find.byKey(
      ValueKey<String>('row-${d.id('Living room')}'),
    );
    await t.ensureVisible(row);
    await t.tap(row);
    await DemoApp.settle(t, 1);
    final Finder trim = find.byKey(
      ValueKey<String>('trim-${d.id('Living room')}'),
    );
    expect(trim, findsOneWidget);
    final Rect r = t.getRect(trim);
    await t.tapAt(Offset(r.left + r.width * 0.5, r.center.dy));
    await DemoApp.settle(t, 1);
    final double level = groupOf(t).trimOf(d.id('Living room'));
    expect(level, inInclusiveRange(0.4, 0.6));
    expect(d.twin('Living room').brightness, (255 * level).round());
    expect(d.twin('Reading lamp').brightness, twinBefore);
    // Collapsed, the row shows its level.
    await t.tap(row);
    await DemoApp.settle(t, 1);
    expect(
      find.byKey(ValueKey<String>('trim-chip-${d.id('Living room')}')),
      findsOneWidget,
    );
    await DemoApp.shutDown(t);
  });

  testWidgets('a change on the light\'s own screen: "Own settings", skipped '
      'by the group, back with Rejoin all', (WidgetTester t) async {
    final DemoApp d = await open(t, DemoApp.groupLights);
    final GroupSession group = groupOf(t);
    await group.setBrightness(200);
    await DemoApp.settle(t, 1);
    final Finder chevron = find.byKey(
      ValueKey<String>('open-${d.id('Living room')}'),
    );
    await t.ensureVisible(chevron);
    await t.tap(chevron);
    await DemoApp.settle(t, 2);
    expect(find.byType(ControlScreen), findsOneWidget);
    await t.drag(
      find.byKey(const ValueKey<String>('brightness')),
      const Offset(-80, 0),
    );
    await DemoApp.settle(t, 1);
    await t.tap(find.byIcon(Icons.chevron_left_rounded).first);
    await DemoApp.settle(t, 2);
    expect(find.byType(ControlScreen), findsNothing);
    expect(find.textContaining('Own settings'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('rejoin-all')), findsOneWidget);

    unawaited(group.setMode(3));
    await DemoApp.settle(t, 2);
    expect(d.twin('Living room').mode, isNot(3));
    expect(d.twin('Reading lamp').mode, 3);

    await t.ensureVisible(find.byKey(const ValueKey<String>('rejoin-all')));
    await t.tap(find.byKey(const ValueKey<String>('rejoin-all')));
    await DemoApp.settle(t, 2);
    expect(find.textContaining('Own settings'), findsNothing);
    expect(d.twin('Living room').mode, 3);
    await DemoApp.shutDown(t);
  });

  testWidgets('no light following: a message and one way back', (
    WidgetTester t,
  ) async {
    final DemoApp d = await open(t, cctW);
    final GroupSession group = groupOf(t);
    for (final String n in cctW.keys) {
      group.setExcluded(d.id(n), excluded: true);
    }
    await DemoApp.settle(t, 1);
    expect(
      find.byKey(const ValueKey<String>('group-none-following')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey<String>('brightness')), findsNothing);
    await t.tap(find.text('Include lights'));
    await DemoApp.settle(t, 2);
    expect(find.byKey(const ValueKey<String>('brightness')), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('group-none-following')),
      findsNothing,
    );
    await DemoApp.shutDown(t);
  });

  testWidgets('no light connected: controls off, and it says so', (
    WidgetTester t,
  ) async {
    await open(t, rgbW, connect: false);
    expect(find.textContaining('No lights connected'), findsOneWidget);
    expect(
      t
          .widget<GlassSlider>(find.byKey(const ValueKey<String>('brightness')))
          .enabled,
      isFalse,
    );
    await DemoApp.shutDown(t);
  });
}
