@Tags(<String>['golden'])
library;

import 'package:electrobright/features/control/control_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/demo_app.dart';

/// The control screen of every fixture type, both themes (RGB + CCT, the
/// busiest, also at 2.0x text). Compared on macOS only, like the gallery.
void main() {
  const Map<String, String> files = <String, String>{
    'Living room': 'rgbw',
    'Desk strip': 'rgb',
    'Bedroom': 'rgbcct',
    'Kitchen': 'cct',
    'Hallway': 'w',
  };
  for (final bool dark in <bool>[false, true]) {
    final String theme = dark ? 'dark' : 'light';
    for (final MapEntry<String, String> e in files.entries) {
      for (final double scale in <double>[1, if (e.value == 'rgbcct') 2]) {
        testWidgets('control ${e.value} $theme ${scale}x', (
          WidgetTester t,
        ) async {
          t.view.physicalSize = const Size(393, 852);
          t.view.devicePixelRatio = 1;
          t.platformDispatcher.platformBrightnessTestValue = dark
              ? Brightness.dark
              : Brightness.light;
          t.platformDispatcher.textScaleFactorTestValue = scale;
          t.platformDispatcher.accessibilityFeaturesTestValue =
              const FakeAccessibilityFeatures(disableAnimations: true);
          addTearDown(t.view.reset);
          addTearDown(t.platformDispatcher.clearAllTestValues);
          final DemoApp d = await DemoApp.start(t);
          await d.open(t, e.key);
          await t.pump(const Duration(milliseconds: 600));
          await expectLater(
            find.byType(ControlScreen),
            matchesGoldenFile(
              'control_${e.value}_${theme}_${scale.toInt()}x.png',
            ),
          );
          await DemoApp.shutDown(t);
        });
      }
    }
  }
}
