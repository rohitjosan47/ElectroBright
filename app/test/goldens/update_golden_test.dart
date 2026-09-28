@Tags(<String>['golden'])
library;

import 'package:electrobright/features/firmware_update/update_firmware_screen.dart';
import 'package:electrobright/features/home/home_screen.dart';
import 'package:electrobright/sessions/connection_manager.dart';
import 'package:electrobright/sim/eb_device_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/demo_app.dart';

/// The firmware version the app bundles (and the demo lights run).
const String _current = EbDeviceModel.firmwareVersion;

/// The firmware update screen of the demo's older light (Desk strip, 3.7.0
/// to the bundled current firmware): during the transfer and when it is done, both
/// themes.
void main() {
  for (final bool dark in <bool>[false, true]) {
    final String theme = dark ? 'dark' : 'light';

    /// App time in 100 ms frames, each with a moment of real time (the
    /// restart's link teardown completes in real async).
    Future<void> settle(WidgetTester t, int seconds) async {
      for (int i = 0; i < seconds * 10; i++) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 1)),
        );
        await t.pump(const Duration(milliseconds: 100));
      }
    }

    Future<DemoApp> updating(WidgetTester t) async {
      t.view.physicalSize = const Size(393, 852);
      t.view.devicePixelRatio = 1;
      t.platformDispatcher.platformBrightnessTestValue = dark
          ? Brightness.dark
          : Brightness.light;
      t.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(t.view.reset);
      addTearDown(t.platformDispatcher.clearAllTestValues);
      final DemoApp d = await DemoApp.start(t, olderFirmware: true);
      final Want w = d.app.ble.connections.want(
        d.id('Desk strip'),
        WantReason.screen,
      );
      addTearDown(w.release);
      await DemoApp.settle(t, 2);
      // Not awaited: the route stays open.
      // ignore: unawaited_futures
      Navigator.of(t.element(find.byType(HomeScreen))).push(
        MaterialPageRoute<void>(
          builder: (_) => UpdateFirmwareScreen(fixtureId: d.id('Desk strip')),
        ),
      );
      await DemoApp.settle(t, 1);
      await t.tap(find.byKey(const ValueKey<String>('update-start')));
      return d;
    }

    testWidgets('update in progress $theme', (WidgetTester t) async {
      await updating(t);
      await DemoApp.settle(t, 2);
      expect(find.text('Sending the firmware…'), findsOneWidget);
      await expectLater(
        find.byType(UpdateFirmwareScreen),
        matchesGoldenFile('update_progress_$theme.png'),
      );
      await DemoApp.shutDown(t);
    });

    testWidgets('update done $theme', (WidgetTester t) async {
      await updating(t);
      await settle(t, 35);
      expect(find.text('Updated to $_current'), findsOneWidget);
      await expectLater(
        find.byType(UpdateFirmwareScreen),
        matchesGoldenFile('update_done_$theme.png'),
      );
      await DemoApp.shutDown(t);
    });
  }
}
