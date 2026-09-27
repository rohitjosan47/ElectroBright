@Tags(<String>['golden'])
library;

import 'dart:async';

import 'package:electrobright/app/providers.dart';
import 'package:electrobright/core/model/channel_layout.dart';
import 'package:electrobright/features/all_lights/all_lights_screen.dart';
import 'package:electrobright/sessions/group_capabilities.dart';
import 'package:electrobright/sessions/group_session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/demo_app.dart';

/// The group screen in both themes: the colour group of three lights with
/// two connected (one RGBW light out of range) on its Colour and Effects
/// tabs; the panel for four mixes of types; and the list with a trimmed, an
/// own-settings and an excluded light.
void main() {
  const Map<String, (GroupKind, Map<String, (String, ChannelLayout)>)> mixes =
      <String, (GroupKind, Map<String, (String, ChannelLayout)>)>{
        'w_only': (
          GroupKind.white,
          <String, (String, ChannelLayout)>{
            'Hallway': ('demo-w', ChannelLayout.w),
            'Porch': ('demo-w-2', ChannelLayout.w),
          },
        ),
        'cct_w': (
          GroupKind.white,
          <String, (String, ChannelLayout)>{
            'Kitchen': ('demo-cct', ChannelLayout.cct),
            'Hallway': ('demo-w', ChannelLayout.w),
          },
        ),
        'rgb_rgbw': (
          GroupKind.colour,
          <String, (String, ChannelLayout)>{
            'Desk strip': ('demo-rgb', ChannelLayout.rgb),
            'Living room': ('demo-rgbw', ChannelLayout.rgbw),
          },
        ),
        'all_types': (GroupKind.colour, DemoApp.lights),
      };

  Future<DemoApp> open(
    WidgetTester t,
    bool dark,
    GroupKind kind,
    Map<String, (String, ChannelLayout)> lights, {
    void Function(DemoApp d)? before,
  }) async {
    t.view.physicalSize = const Size(393, 852);
    t.view.devicePixelRatio = 1;
    t.platformDispatcher.platformBrightnessTestValue = dark
        ? Brightness.dark
        : Brightness.light;
    t.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(t.view.reset);
    addTearDown(t.platformDispatcher.clearAllTestValues);
    final DemoApp d = await DemoApp.start(t, lights: lights);
    before?.call(d);
    unawaited(
      t
          .state<NavigatorState>(find.byType(Navigator).first)
          .push(
            MaterialPageRoute<void>(
              builder: (_) => AllLightsScreen(kind: kind),
            ),
          ),
    );
    await DemoApp.settle(t, 5);
    return d;
  }

  for (final bool dark in <bool>[false, true]) {
    final String theme = dark ? 'dark' : 'light';
    for (final String tab in <String>['colour', 'effects']) {
      testWidgets('all lights $theme $tab', (WidgetTester t) async {
        await open(
          t,
          dark,
          GroupKind.colour,
          DemoApp.groupLights,
          before: (DemoApp d) =>
              d.radio.setAvailable('demo-rgbw-2', available: false),
        );
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

    for (final MapEntry<
          String,
          (GroupKind, Map<String, (String, ChannelLayout)>)
        >
        mix
        in mixes.entries) {
      testWidgets('all lights ${mix.key} $theme', (WidgetTester t) async {
        await open(t, dark, mix.value.$1, mix.value.$2);
        await t.pump(const Duration(milliseconds: 600));
        await expectLater(
          find.byType(AllLightsScreen),
          matchesGoldenFile('all_lights_${mix.key}_$theme.png'),
        );
        await DemoApp.shutDown(t);
      });
    }

    testWidgets('all lights list $theme', (WidgetTester t) async {
      final DemoApp d = await open(
        t,
        dark,
        GroupKind.colour,
        DemoApp.groupLights,
      );
      final GroupSession group = ProviderScope.containerOf(
        t.element(find.byType(AllLightsScreen)),
      ).read(groupSessionProvider(GroupKind.colour))!;
      await group.setBrightness(200);
      await DemoApp.settle(t, 1);
      group.setTrim(d.id('Living room'), 0.5);
      // Changed on its own screen: own settings.
      d.session('Desk strip').setBrightness(90);
      group.setExcluded(d.id('Reading lamp'), excluded: true);
      await DemoApp.settle(t, 2);
      await t.scrollUntilVisible(
        find.byKey(ValueKey<String>('group-light-${d.id('Reading lamp')}')),
        200,
        scrollable: find
            .descendant(
              of: find.byType(AllLightsScreen),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await t.pump(const Duration(milliseconds: 600));
      await expectLater(
        find.byType(AllLightsScreen),
        matchesGoldenFile('all_lights_list_$theme.png'),
      );
      await DemoApp.shutDown(t);
    });
  }
}
