import 'dart:async';

import 'package:electrobright/features/control/control_screen.dart';
import 'package:electrobright/features/fixture_settings/light_settings_screen.dart';
import 'package:electrobright/sim/eb_device_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/demo_app.dart';

/// Light settings of each type: what it can do, channel test, factory reset
/// and forget — checked against the demo twins.
void main() {
  Future<void> settle(WidgetTester t, [int seconds = 2]) =>
      DemoApp.settle(t, seconds);

  /// Pumps 100 ms at a time until exactly one widget matches [finder] (at
  /// most [seconds]).
  Future<void> until(WidgetTester t, Finder finder, {int seconds = 4}) async {
    for (int i = 0; i < seconds * 10; i++) {
      if (finder.evaluate().length == 1) return;
      await t.pump(const Duration(milliseconds: 100));
    }
    expect(finder, findsOneWidget);
  }

  Future<DemoApp> open(WidgetTester t, String name) async {
    t.view.physicalSize = const Size(1179, 7000);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    final DemoApp d = await DemoApp.start(t);
    await d.open(t, name);
    await t.tap(find.byKey(const ValueKey<String>('settings-button')));
    await settle(t, 1);
    expect(find.byType(LightSettingsScreen), findsOneWidget);
    return d;
  }

  testWidgets('single white: what it can do', (WidgetTester t) async {
    await open(t, 'Hallway');
    await t.tap(find.byKey(const ValueKey<String>('settings-caps')));
    await settle(t, 1);
    expect(find.text('12 of 13'), findsOneWidget);
    expect(find.text('15 on the light'), findsOneWidget);
    expect(
      find.text("Rainbow isn't available on single-white lights."),
      findsOneWidget,
    );
    expect(find.text('EB-C3-W-V1'), findsOneWidget);
    expect(find.text(EbDeviceModel.firmwareVersion), findsOneWidget);
    await DemoApp.shutDown(t);
  });

  testWidgets('no LED calibration to set: white points are the product\'s', (
    WidgetTester t,
  ) async {
    await open(t, 'Kitchen');
    expect(find.text('LED CALIBRATION'), findsNothing);
    expect(find.text('LED calibration'), findsNothing);
    expect(find.text('Reset to defaults'), findsNothing);
    expect(find.byTooltip('+100 K'), findsNothing);
    for (final String k in <String>['led-w', 'led-cw', 'led-ww']) {
      expect(find.byKey(ValueKey<String>(k)), findsNothing);
    }
    // The rest of the screen is still there.
    expect(find.byKey(const ValueKey<String>('settings-caps')), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('settings-identify')),
      findsOneWidget,
    );
    await DemoApp.shutDown(t);
  });

  testWidgets('channel test lights every LED, then restores the look', (
    WidgetTester t,
  ) async {
    final DemoApp d = await open(t, 'Bedroom');
    final List<int> before = d.twin('Bedroom').color.values;
    await t.tap(find.byKey(const ValueKey<String>('settings-channel-test')));
    await t.pump(const Duration(milliseconds: 600));
    expect(find.text('Lighting Red'), findsOneWidget);
    expect(d.twin('Bedroom').color.values, <int>[255, 0, 0, 0, 0]);
    // Each LED is reported once the light confirmed it: the twin already
    // shows it when its name appears.
    await until(t, find.text('Lighting Cool white'));
    expect(d.twin('Bedroom').color.values, <int>[0, 0, 0, 255, 0]);
    await until(t, find.text('Lighting Warm white'));
    expect(d.twin('Bedroom').color.values, <int>[0, 0, 0, 0, 255]);
    // The last LED gets its whole 1.2 s before the look comes back.
    await settle(t, 1);
    expect(find.text('Lighting Warm white'), findsOneWidget);
    expect(d.twin('Bedroom').color.values, <int>[0, 0, 0, 0, 255]);
    await settle(t, 3);
    expect(d.twin('Bedroom').color.values, before);
    expect(find.textContaining('Lighting'), findsNothing);
    await DemoApp.shutDown(t);
  });

  testWidgets('factory reset asks first, then restores the factory look', (
    WidgetTester t,
  ) async {
    final DemoApp d = await open(t, 'Desk strip');
    d.session('Desk strip').setBrightness(60);
    await settle(t);
    expect(d.twin('Desk strip').brightness, 60);
    await t.tap(find.byKey(const ValueKey<String>('settings-reset')));
    await settle(t, 1);
    expect(find.text('Factory look: '), findsOneWidget);
    await t.tap(find.text('Erase'));
    await settle(t, 3);
    expect(d.twin('Desk strip').brightness, 255);
    await DemoApp.shutDown(t);
  });

  testWidgets('forget returns to Home without the light', (
    WidgetTester t,
  ) async {
    final DemoApp d = await open(t, 'Living room');
    await t.tap(find.byKey(const ValueKey<String>('settings-forget')));
    await settle(t, 1);
    await t.tap(find.text('Forget'));
    await settle(t);
    expect(find.byType(LightSettingsScreen), findsNothing);
    expect(find.text('Lights'), findsOneWidget);
    expect(d.app.registry.byId(DemoApp.idOf('Living room')), isNull);
    // Forgotten on purpose: no "removed" notice.
    expect(find.text('This light was removed'), findsNothing);
    await DemoApp.shutDown(t);
  });

  testWidgets('a light removed while its screens are open closes to Home', (
    WidgetTester t,
  ) async {
    final DemoApp d = await open(t, 'Desk strip');
    // Settings over the control screen: both close, one message.
    bool gone = false;
    unawaited(
      d.app.registry.forget(d.id('Desk strip')).then((_) => gone = true),
    );
    // Tearing its session down takes real time as well as app time.
    for (int i = 0; i < 50 && !gone; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await t.pump(const Duration(milliseconds: 100));
    }
    expect(gone, isTrue);
    await settle(t, 1);
    expect(find.byType(LightSettingsScreen), findsNothing);
    expect(find.byType(ControlScreen), findsNothing);
    expect(find.text('Lights'), findsOneWidget);
    expect(find.text('This light was removed'), findsOneWidget);
    await settle(t, 3);
    expect(find.text('This light was removed'), findsNothing);
    await DemoApp.shutDown(t);
  });
}
