import 'package:electrobright/core/protocol/eb/eb_constants.dart';
import 'package:electrobright/design/components/glass_controls.dart';
import 'package:electrobright/features/control/control_screen.dart';
import 'package:electrobright/features/control/timer_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/demo_app.dart';

/// Presets, police beacons, timer and sound on the control screen, checked
/// against the firmware twin of each light type.
void main() {
  Finder tab(String name) => find.descendant(
    of: find.byType(GlassSegmented<ControlTab>),
    matching: find.text(name),
  );

  Future<void> settle(WidgetTester t, [int seconds = 2]) =>
      DemoApp.settle(t, seconds);

  Future<DemoApp> open(WidgetTester t, String name) async {
    t.view.physicalSize = const Size(1179, 7000);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    final DemoApp demo = await DemoApp.start(t);
    await demo.open(t, name);
    return demo;
  }

  testWidgets('presets: save with a name, load, "Modified from", clear', (
    WidgetTester t,
  ) async {
    final DemoApp d = await open(t, 'Hallway');
    await t.tap(tab('Presets'));
    await settle(t, 1);
    expect(find.byKey(const ValueKey<String>('preset-24')), findsOneWidget);
    // Save the current look in slot 1, named.
    await t.tap(find.byKey(const ValueKey<String>('preset-0')));
    await settle(t, 1);
    await t.tap(find.text('Cozy Warmth'));
    await t.tap(find.text('Save'));
    await settle(t);
    expect(d.model('Hallway').presetSlots, contains(0));
    expect(find.text('Current look: Cozy Warmth'), findsOneWidget);
    // Change the look: the preset is no longer active.
    d.session('Hallway').setBrightness(40);
    await settle(t);
    expect(find.text('Modified from Cozy Warmth'), findsOneWidget);
    // Load it back.
    await t.tap(find.byKey(const ValueKey<String>('preset-0')));
    await settle(t);
    expect(d.twin('Hallway').brightness, 255);
    expect(find.text('Current look: Cozy Warmth'), findsOneWidget);
    // The preview names the effect and the output.
    expect(find.text('Solid Color · 100 %'), findsOneWidget);
    // Clear it.
    await t.longPress(find.byKey(const ValueKey<String>('preset-0')));
    await settle(t, 1);
    await t.tap(find.text('Clear'));
    await settle(t);
    expect(d.model('Hallway').presetSlots, isNot(contains(0)));
    expect(find.text('Cozy Warmth'), findsNothing);
    await DemoApp.shutDown(t);
  });

  testWidgets('police beacons on a tunable-white light are whites', (
    WidgetTester t,
  ) async {
    final DemoApp d = await open(t, 'Kitchen');
    await t.tap(tab('Effects'));
    await settle(t, 1);
    await t.tap(find.byKey(const ValueKey<String>('mode-12')));
    await settle(t);
    expect(d.twin('Kitchen').mode, 12);
    // Its colour source in its own words; beacons need "Your white".
    expect(find.text('Warm & cool'), findsOneWidget);
    if (d.twin('Kitchen').policeColorMode != 0) {
      await t.tap(find.text('Your white'));
      await settle(t);
    }
    await t.tap(find.text('Beacon A'));
    await settle(t, 1);
    await t.tap(find.text('Warm 2700 K').last);
    await settle(t);
    // Two values: cool and warm white.
    expect(d.twin('Kitchen').policeA.values, <int>[0, 255]);
    await DemoApp.shutDown(t);
  });

  testWidgets('sleep timer and sound reach the light', (WidgetTester t) async {
    final DemoApp d = await open(t, 'Desk strip');
    final bool sound = d.model('Desk strip').soundOn;
    await t.tap(find.byKey(const ValueKey<String>('sound-button')));
    await settle(t);
    expect(d.model('Desk strip').soundOn, !sound);

    expect(find.byKey(const ValueKey<String>('timer-left')), findsNothing);
    await t.tap(find.byKey(const ValueKey<String>('timer-button')));
    await settle(t, 1);
    await t.tap(find.byKey(const ValueKey<String>('timer-start')));
    await settle(t);
    expect(d.model('Desk strip').timerActive, isTrue);
    // 10 minutes (the default step).
    expect(d.model('Desk strip').timerRemainingSec, inInclusiveRange(590, 600));
    expect(find.byKey(const ValueKey<String>('timer-left')), findsOneWidget);
    expect(Eb.timerMaxSeconds, 86400);
    // Running: one action, cancel.
    await t.tap(find.byKey(const ValueKey<String>('timer-button')));
    await settle(t, 1);
    expect(find.byKey(const ValueKey<String>('timer-start')), findsNothing);
    expect(find.byKey(const ValueKey<String>('timer-cancel')), findsOneWidget);
    await t.tap(find.byKey(const ValueKey<String>('timer-cancel')));
    await settle(t);
    expect(d.model('Desk strip').timerActive, isFalse);
    expect(find.byKey(const ValueKey<String>('timer-left')), findsNothing);
    // Idle again: start only.
    await t.tap(find.byKey(const ValueKey<String>('timer-button')));
    await settle(t, 1);
    expect(find.byKey(const ValueKey<String>('timer-start')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('timer-cancel')), findsNothing);
    await DemoApp.shutDown(t);
  });

  testWidgets('sleep timer ring counts down the duration it was started with', (
    WidgetTester t,
  ) async {
    final DemoApp d = await open(t, 'Desk strip');
    TimerDial dial() => t.widget<TimerDial>(find.byType(TimerDial));

    // Start a 1 min timer (not the 10 min default).
    await t.tap(find.byKey(const ValueKey<String>('timer-button')));
    await settle(t, 1);
    expect(dial().progress, isNull);
    dial().onChanged(timerSteps.indexOf(const Duration(minutes: 1)));
    await t.pump();
    await t.tap(find.byKey(const ValueKey<String>('timer-start')));
    await settle(t);
    expect(d.model('Desk strip').timerRemainingSec, inInclusiveRange(58, 60));

    // Half-way: the reopened sheet shows half a ring and the countdown.
    await settle(t, 28);
    await t.tap(find.byKey(const ValueKey<String>('timer-button')));
    await settle(t, 1);
    expect(dial().progress, closeTo(0.5, 0.05));
    expect(find.textContaining('Off in 0:'), findsWidgets);

    // The dial is read-only while running and turning it moves nothing.
    final double before = dial().progress!;
    final Rect box = t.getRect(find.byType(TimerDial));
    await t.dragFrom(
      box.topCenter + const Offset(40, 20),
      const Offset(80, 80),
    );
    await t.pump();
    dial().onChanged(timerSteps.length - 1);
    await t.pump();
    // Only the countdown itself (the gesture's own second) moves the ring.
    expect(dial().progress, closeTo(before, 0.05));
    expect(d.model('Desk strip').timerRemainingSec, inInclusiveRange(28, 31));
    await DemoApp.shutDown(t);
  });
}
