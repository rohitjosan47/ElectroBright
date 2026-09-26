@Tags(<String>['golden'])
library;

import 'package:electrobright/features/home/home_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/demo_app.dart';

/// The All Lights card and header button on Home (five demo lights, Home's
/// three connected), both themes.
void main() {
  for (final bool dark in <bool>[false, true]) {
    final String theme = dark ? 'dark' : 'light';
    testWidgets('home all lights card $theme', (WidgetTester t) async {
      t.view.physicalSize = const Size(393, 852);
      t.view.devicePixelRatio = 1;
      t.platformDispatcher.platformBrightnessTestValue = dark
          ? Brightness.dark
          : Brightness.light;
      t.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(t.view.reset);
      addTearDown(t.platformDispatcher.clearAllTestValues);
      await DemoApp.start(t);
      await DemoApp.settle(t, 3);
      await expectLater(
        find.byType(HomeScreen),
        matchesGoldenFile('home_all_lights_card_$theme.png'),
      );
      await DemoApp.shutDown(t);
    });
  }
}
