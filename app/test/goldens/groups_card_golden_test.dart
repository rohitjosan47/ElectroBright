@Tags(<String>['golden'])
library;

import 'package:electrobright/core/model/channel_layout.dart';
import 'package:electrobright/features/home/home_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/demo_app.dart';

/// The Groups card on Home in both themes: both groups (five demo lights,
/// Home's three connected) and a single group at full width.
void main() {
  const Map<String, Map<String, (String, ChannelLayout)>> cases =
      <String, Map<String, (String, ChannelLayout)>>{
        'both': DemoApp.lights,
        'single': <String, (String, ChannelLayout)>{
          'Desk strip': ('demo-rgb', ChannelLayout.rgb),
          'Living room': ('demo-rgbw', ChannelLayout.rgbw),
          'Kitchen': ('demo-cct', ChannelLayout.cct),
        },
      };
  for (final bool dark in <bool>[false, true]) {
    final String theme = dark ? 'dark' : 'light';
    for (final MapEntry<String, Map<String, (String, ChannelLayout)>> c
        in cases.entries) {
      testWidgets('groups card ${c.key} $theme', (WidgetTester t) async {
        t.view.physicalSize = const Size(393, 852);
        t.view.devicePixelRatio = 1;
        t.platformDispatcher.platformBrightnessTestValue = dark
            ? Brightness.dark
            : Brightness.light;
        t.platformDispatcher.accessibilityFeaturesTestValue =
            const FakeAccessibilityFeatures(disableAnimations: true);
        addTearDown(t.view.reset);
        addTearDown(t.platformDispatcher.clearAllTestValues);
        await DemoApp.start(t, lights: c.value);
        await DemoApp.settle(t, 3);
        await expectLater(
          find.byType(HomeScreen),
          matchesGoldenFile('groups_card_${c.key}_$theme.png'),
        );
        await DemoApp.shutDown(t);
      });
    }
  }
}
