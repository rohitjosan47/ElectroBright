@Tags(<String>['golden'])
library;

import 'package:electrobright/features/add_fixture/add_light_screen.dart';
import 'package:electrobright/features/home/home_screen.dart';
import 'package:electrobright/sim/sim_central.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/demo_app.dart';

/// Home with two lights nearby (the badge on "Add light"), and the add
/// screen with one light nearby and the unsupported section, both themes.
void main() {
  for (final bool dark in <bool>[false, true]) {
    final String theme = dark ? 'dark' : 'light';

    Future<DemoApp> start(WidgetTester t, {required int extra}) async {
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
      for (int i = 1; i <= extra; i++) {
        d.radio.fixtures.add(SimFixture.electroBright(id: 'demo-extra-$i'));
      }
      await DemoApp.settle(t, 3);
      return d;
    }

    testWidgets('home with the nearby badge $theme', (WidgetTester t) async {
      await start(t, extra: 2);
      await expectLater(
        find.byType(HomeScreen),
        matchesGoldenFile('home_badge_$theme.png'),
      );
      await DemoApp.shutDown(t);
    });

    testWidgets('add screen with unsupported lights $theme', (
      WidgetTester t,
    ) async {
      await start(t, extra: 1);
      await t.tap(find.text('Add light'));
      await DemoApp.settle(t, 2);
      expect(find.text('Unsupported lights'), findsOneWidget);
      await expectLater(
        find.byType(AddLightScreen),
        matchesGoldenFile('add_unsupported_$theme.png'),
      );
      await DemoApp.shutDown(t);
    });
  }
}
