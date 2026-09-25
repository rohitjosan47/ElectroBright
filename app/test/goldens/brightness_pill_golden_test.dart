@Tags(<String>['golden'])
library;

import 'package:electrobright/features/control/control_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/demo_app.dart';

/// The brightness pill at Off, 2 %, 25 %, 70 % and 100 % on an RGBW and a
/// single-white light, both themes: the top of the control screen, so the
/// canvas glow and the orb following the level are in the picture too.
void main() {
  const Map<String, String> lights = <String, String>{
    'Living room': 'rgbw',
    'Hallway': 'w',
  };
  const Map<String, int?> levels = <String, int?>{
    'off': null,
    '02': 5,
    '25': 64,
    '70': 179,
    '100': 255,
  };
  for (final bool dark in <bool>[false, true]) {
    final String theme = dark ? 'dark' : 'light';
    for (final MapEntry<String, String> light in lights.entries) {
      for (final MapEntry<String, int?> level in levels.entries) {
        testWidgets('pill ${light.value} $theme ${level.key}', (
          WidgetTester t,
        ) async {
          t.view.physicalSize = const Size(393, 852);
          t.view.devicePixelRatio = 1;
          t.platformDispatcher.platformBrightnessTestValue = dark
              ? Brightness.dark
              : Brightness.light;
          t.platformDispatcher.accessibilityFeaturesTestValue =
              const FakeAccessibilityFeatures(disableAnimations: true);
          addTearDown(t.view.reset);
          addTearDown(t.platformDispatcher.clearAllTestValues);
          final DemoApp d = await DemoApp.start(t);
          await d.open(t, light.key);
          d.session(light.key).setBrightness(level.value ?? 0);
          await DemoApp.settle(t, 2);
          // Only the top: header, orb, toolbar and the pill.
          t.view.physicalSize = const Size(393, 400);
          await t.pump();
          await expectLater(
            find.byType(ControlScreen),
            matchesGoldenFile(
              'brightness_pill/pill_${light.value}_${theme}_${level.key}.png',
            ),
          );
          await DemoApp.shutDown(t);
        });
      }
    }
  }
}
