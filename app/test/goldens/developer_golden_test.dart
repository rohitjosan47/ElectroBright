@Tags(<String>['golden'])
library;

import 'package:electrobright/features/developer/developer_screen.dart';
import 'package:electrobright/features/developer/light_developer_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/demo_app.dart';

/// Settings → Developer (every light) and a light's developer page (its
/// type, the type list, firmware and diagnostics), both themes.
void main() {
  for (final bool dark in <bool>[false, true]) {
    final String theme = dark ? 'dark' : 'light';

    Future<DemoApp> developer(WidgetTester t) async {
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
      await t.tap(find.bySemanticsLabel('Settings'));
      await DemoApp.settle(t, 1);
      await t.tap(
        find.byKey(const ValueKey<String>('settings-developer-tools')),
      );
      await DemoApp.settle(t, 1);
      await t.tap(find.byKey(const ValueKey<String>('settings-developer')));
      await DemoApp.settle(t, 2);
      return d;
    }

    testWidgets('developer $theme', (WidgetTester t) async {
      await developer(t);
      await expectLater(
        find.byType(DeveloperScreen),
        matchesGoldenFile('developer_$theme.png'),
      );
      await DemoApp.shutDown(t);
    });

    testWidgets('light developer $theme', (WidgetTester t) async {
      final DemoApp d = await developer(t);
      await t.tap(find.byKey(ValueKey<String>('dev-light-${d.id('Bedroom')}')));
      await DemoApp.settle(t, 2);
      await expectLater(
        find.byType(LightDeveloperScreen),
        matchesGoldenFile('light_developer_$theme.png'),
      );
      await DemoApp.shutDown(t);
    });
  }
}
