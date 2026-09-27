@Tags(<String>['golden'])
library;

import 'dart:async';

import 'package:electrobright/app/providers.dart';
import 'package:electrobright/core/color/colour_engine.dart';
import 'package:electrobright/core/color/hsv.dart';
import 'package:electrobright/core/model/channel_layout.dart';
import 'package:electrobright/features/groups/group_screen.dart';
import 'package:electrobright/sessions/group_capabilities.dart';
import 'package:electrobright/sessions/group_session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/demo_app.dart';

/// The group screens in both themes: the colour group on its Colour and
/// Presets tabs; the white group with a tunable and a single white (White
/// tab); the white group of single whites only.
void main() {
  const Map<String, (String, ChannelLayout)> cctW =
      <String, (String, ChannelLayout)>{
        'Kitchen': ('demo-cct', ChannelLayout.cct),
        'Hallway': ('demo-w', ChannelLayout.w),
      };
  const Map<String, (String, ChannelLayout)> wOnly =
      <String, (String, ChannelLayout)>{
        'Hallway': ('demo-w', ChannelLayout.w),
        'Porch': ('demo-w-2', ChannelLayout.w),
      };

  Future<DemoApp> open(
    WidgetTester t,
    bool dark,
    GroupKind kind,
    Map<String, (String, ChannelLayout)> lights,
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
    final DemoApp d = await DemoApp.start(t, lights: lights);
    unawaited(
      t
          .state<NavigatorState>(find.byType(Navigator).first)
          .push(
            MaterialPageRoute<void>(builder: (_) => GroupScreen(kind: kind)),
          ),
    );
    await DemoApp.settle(t, 5);
    return d;
  }

  GroupSession groupOf(WidgetTester t, GroupKind kind) =>
      ProviderScope.containerOf(t.element(find.byType(GroupScreen)))
          .read(groupSessionProvider(kind))!;

  Future<void> expectGolden(WidgetTester t, String file) async {
    await t.pump(const Duration(milliseconds: 600));
    await expectLater(find.byType(GroupScreen), matchesGoldenFile(file));
    await DemoApp.shutDown(t);
  }

  for (final bool dark in <bool>[false, true]) {
    final String theme = dark ? 'dark' : 'light';

    testWidgets('group colour colour $theme', (WidgetTester t) async {
      await open(t, dark, GroupKind.colour, DemoApp.groupLights);
      await expectGolden(t, 'group_colour_colour_$theme.png');
    });

    testWidgets('group colour presets $theme', (WidgetTester t) async {
      await open(t, dark, GroupKind.colour, DemoApp.groupLights);
      final GroupSession group = groupOf(t, GroupKind.colour);
      await group.setBrightness(200);
      await group.setColour(const HsvIntent(Hsv(20, 0.9, 1)));
      await DemoApp.settle(t, 1);
      group.savePreset(0, 'Sunset');
      await group.setColour(const HsvIntent(Hsv(200, 1, 1)));
      await DemoApp.settle(t, 1);
      group.savePreset(1, 'Ocean');
      await group.applyPreset(0);
      await DemoApp.settle(t, 1);
      await t.tap(find.text('Presets'));
      await DemoApp.settle(t, 1);
      await expectGolden(t, 'group_colour_presets_$theme.png');
    });

    testWidgets('group white cct w white $theme', (WidgetTester t) async {
      await open(t, dark, GroupKind.white, cctW);
      await expectGolden(t, 'group_white_cct_w_white_$theme.png');
    });

    testWidgets('group white w only $theme', (WidgetTester t) async {
      await open(t, dark, GroupKind.white, wOnly);
      await expectGolden(t, 'group_white_w_only_$theme.png');
    });
  }
}
