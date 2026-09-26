@Tags(<String>['golden'])
library;

import 'dart:async';

import 'package:electrobright/features/all_lights/all_lights_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/demo_app.dart';

/// All Lights with five lights, four connected (the single white is out of
/// range), on its Colour and Effects tabs, both themes.
void main() {
  for (final bool dark in <bool>[false, true]) {
    final String theme = dark ? 'dark' : 'light';
    for (final String tab in <String>['colour', 'effects']) {
      testWidgets('all lights $theme $tab', (WidgetTester t) async {
        t.view.physicalSize = const Size(393, 852);
        t.view.devicePixelRatio = 1;
        t.platformDispatcher.platformBrightnessTestValue = dark
            ? Brightness.dark
            : Brightness.light;
        t.platformDispatcher.accessibilityFeaturesTestValue =
            const FakeAccessibilityFeatures(disableAnimations: true);
        addTearDown(t.view.reset);
        addTearDown(t.platformDispatcher.clearAllTestValues);
        final DemoApp d = await DemoApp.start(t, lights: DemoApp.groupLights);
        d.radio.setAvailable('demo-w', available: false);
        unawaited(
          t
              .state<NavigatorState>(find.byType(Navigator).first)
              .push(
                MaterialPageRoute<void>(
                  builder: (_) => const AllLightsScreen(),
                ),
              ),
        );
        await DemoApp.settle(t, 5);
        if (tab == 'effects') {
          await t.tap(find.text('Effects'));
          await DemoApp.settle(t, 1);
        }
        await t.pump(const Duration(milliseconds: 600));
        await expectLater(
          find.byType(AllLightsScreen),
          matchesGoldenFile('all_lights_${theme}_$tab.png'),
        );
        await DemoApp.shutDown(t);
      });
    }
  }
}
