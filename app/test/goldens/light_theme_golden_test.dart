@Tags(<String>['golden'])
library;

import 'package:electrobright/core/model/channel_color.dart';
import 'package:electrobright/design/components/glass_controls.dart';
import 'package:electrobright/features/control/control_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/demo_app.dart';

/// The light theme's control screen on each tab: an RGBW light in white,
/// magenta and yellow, a single-white light and an RGB + CCT light.
void main() {
  final Map<String, (String, ChannelColor?)> lights =
      <String, (String, ChannelColor?)>{
        'rgbw_white': ('Living room', null),
        'rgbw_magenta': ('Living room', ChannelColor.rgbw(255, 0, 255, 0)),
        'rgbw_yellow': ('Living room', ChannelColor.rgbw(255, 255, 0, 0)),
        'w': ('Hallway', null),
        'rgbcct': ('Bedroom', null),
      };
  for (final MapEntry<String, (String, ChannelColor?)> light
      in lights.entries) {
    final List<String> tabs = light.key == 'w'
        ? <String>['Effects', 'Presets']
        : <String>['Colour', 'Effects', 'Presets'];
    for (final String tab in tabs) {
      testWidgets('light theme ${light.key} ${tab.toLowerCase()}', (
        WidgetTester t,
      ) async {
        t.view.physicalSize = const Size(393, 852);
        t.view.devicePixelRatio = 1;
        t.platformDispatcher.platformBrightnessTestValue = Brightness.light;
        t.platformDispatcher.accessibilityFeaturesTestValue =
            const FakeAccessibilityFeatures(disableAnimations: true);
        addTearDown(t.view.reset);
        addTearDown(t.platformDispatcher.clearAllTestValues);
        final DemoApp d = await DemoApp.start(t);
        final (String name, ChannelColor? colour) = light.value;
        await d.open(t, name);
        if (colour != null) d.session(name).setColor(colour);
        await t.tap(
          find.descendant(
            of: find.byType(GlassSegmented<ControlTab>),
            matching: find.text(tab),
          ),
        );
        await DemoApp.settle(t, 2);
        await expectLater(
          find.byType(ControlScreen),
          matchesGoldenFile(
            'light/control_${light.key}_${tab.toLowerCase()}.png',
          ),
        );
        await DemoApp.shutDown(t);
      });
    }
  }
}
