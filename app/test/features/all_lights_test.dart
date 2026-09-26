import 'dart:async';

import 'package:electrobright/core/color/colour_engine.dart';
import 'package:electrobright/core/color/hsv.dart';
import 'package:electrobright/core/model/channel_color.dart';
import 'package:electrobright/features/all_lights/all_lights_screen.dart';
import 'package:electrobright/features/control/colour/colour_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/demo_app.dart';

/// All Lights with an RGB, two identical RGBW lights, a tunable white and a
/// single white (simulated).
void main() {
  const List<String> all = <String>[
    'Desk strip',
    'Living room',
    'Reading lamp',
    'Kitchen',
    'Hallway',
  ];
  const int rainbow = 10;

  Future<DemoApp> open(WidgetTester t) async {
    t.view.physicalSize = const Size(393, 2600);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final DemoApp d = await DemoApp.start(t, lights: DemoApp.groupLights);
    await DemoApp.settle(t, 1);
    openAllLights(t);
    await DemoApp.settle(t, 5);
    expect(find.byType(AllLightsScreen), findsOneWidget);
    expect(find.text('5 of 5 connected'), findsOneWidget);
    return d;
  }

  /// Sends a colour as the editor does (its intent output).
  Future<void> pick(WidgetTester t, ColourIntent intent) async {
    final ColourEditor editor = t.widget<ColourEditor>(
      find.byType(ColourEditor),
    );
    final ChannelColor c = const ColourEngine().encode(
      intent,
      editor.value.layout,
    );
    editor.onChanged(c, live: false, intent: intent);
    await DemoApp.settle(t, 1);
  }

  testWidgets('mixed brightness says so; the first drag sets every light', (
    WidgetTester t,
  ) async {
    final DemoApp d = await open(t);
    d.session('Desk strip').setBrightness(60);
    await DemoApp.settle(t, 1);
    expect(find.text('Mixed'), findsOneWidget);

    await t.drag(
      find.byKey(const ValueKey<String>('brightness')),
      const Offset(-60, 0),
    );
    await DemoApp.settle(t, 1);
    expect(find.text('Mixed'), findsNothing);
    final int b = d.twin('Desk strip').brightness;
    expect(b, isNot(60));
    for (final String n in all) {
      expect(d.twin(n).brightness, b, reason: n);
    }
    await DemoApp.shutDown(t);
  });

  testWidgets('a colour reaches the colour lights; whites follow in white', (
    WidgetTester t,
  ) async {
    final DemoApp d = await open(t);
    const HsvIntent red = HsvIntent(Hsv(0, 1, 1));
    await pick(t, red);
    expect(d.twin('Desk strip').color[0], 255);
    expect(d.twin('Desk strip').color[1], 0);
    for (final String n in <String>['Living room', 'Reading lamp']) {
      expect(d.twin(n).color.values, <int>[255, 0, 0, 0], reason: n);
      expect(d.session(n).status.colourPick?.intent, red, reason: n);
    }
    expect(d.session('Kitchen').status.colourPick?.intent, isA<WhiteIntent>());
    expect(d.twin('Hallway').color.values, <int>[255]);
    await DemoApp.shutDown(t);
  });

  testWidgets('Rainbow shows how many lights have it and goes to those', (
    WidgetTester t,
  ) async {
    final DemoApp d = await open(t);
    await t.tap(find.text('Effects'));
    await DemoApp.settle(t, 1);
    // The single white has no Rainbow; the tunable white's firmware has it.
    expect(find.text('4/5'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey<String>('mode-$rainbow')));
    await DemoApp.settle(t, 2);
    for (final String n in all.where((String n) => n != 'Hallway')) {
      expect(d.twin(n).mode, rainbow, reason: n);
    }
    expect(d.twin('Hallway').mode, 1);
    expect(find.text('Applied to 4 of 5 lights'), findsOneWidget);
    await DemoApp.shutDown(t);
  });

  testWidgets('the sleep timer starts and is cancelled on every light', (
    WidgetTester t,
  ) async {
    final DemoApp d = await open(t);
    await t.tap(find.byKey(const ValueKey<String>('timer-button')));
    await DemoApp.settle(t, 1);
    await t.tap(find.byKey(const ValueKey<String>('timer-start')));
    await DemoApp.settle(t, 2);
    for (final String n in all) {
      expect(d.model(n).timerActive, isTrue, reason: n);
    }
    expect(find.byKey(const ValueKey<String>('timer-left')), findsOneWidget);

    await t.tap(find.byKey(const ValueKey<String>('timer-button')));
    await DemoApp.settle(t, 1);
    await t.tap(find.byKey(const ValueKey<String>('timer-cancel')));
    await DemoApp.settle(t, 2);
    for (final String n in all) {
      expect(d.model(n).timerActive, isFalse, reason: n);
    }
    expect(find.byKey(const ValueKey<String>('timer-left')), findsNothing);
    await DemoApp.shutDown(t);
  });

  testWidgets('Identify flashes only its own light, not its identical twin', (
    WidgetTester t,
  ) async {
    final DemoApp d = await open(t);
    final Set<int> a = <int>{}, b = <int>{};
    final Finder button = find.byKey(
      ValueKey<String>('identify-${d.id('Living room')}'),
    );
    await t.ensureVisible(button);
    await t.tap(button);
    for (int i = 0; i < 30; i++) {
      await t.pump(const Duration(milliseconds: 50));
      a.add(d.twin('Living room').brightness);
      b.add(d.twin('Reading lamp').brightness);
    }
    expect(a, contains(0));
    expect(b, hasLength(1));
    await DemoApp.shutDown(t);
  });

  testWidgets('leaving out one RGBW light leaves its twin working', (
    WidgetTester t,
  ) async {
    final DemoApp d = await open(t);
    final Finder include = find.byKey(
      ValueKey<String>('include-${d.id('Reading lamp')}'),
    );
    await t.ensureVisible(include);
    await t.tap(include);
    await DemoApp.settle(t, 1);
    expect(find.text('4 of 4 connected'), findsOneWidget);
    final ChannelColor before = d.twin('Reading lamp').color;
    await t.ensureVisible(find.byType(ColourEditor));
    await pick(t, const HsvIntent(Hsv(120, 1, 1)));
    expect(d.twin('Living room').color.values, <int>[0, 255, 0, 0]);
    expect(d.twin('Reading lamp').color, before);
    await DemoApp.shutDown(t);
  });
}

/// Opens All Lights over Home.
void openAllLights(WidgetTester t) => unawaited(
  t
      .state<NavigatorState>(find.byType(Navigator).first)
      .push(MaterialPageRoute<void>(builder: (_) => const AllLightsScreen())),
);
