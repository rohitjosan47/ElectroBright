import 'package:electrobright/app/providers.dart';
import 'package:electrobright/core/color/colour_engine.dart';
import 'package:electrobright/design/controls/hue_wheel.dart';
import 'package:electrobright/features/control/presets/preset_slots.dart';
import 'package:electrobright/features/groups/group_screen.dart';
import 'package:electrobright/sessions/group_capabilities.dart';
import 'package:electrobright/sessions/group_presets.dart';
import 'package:electrobright/sessions/group_session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/demo_app.dart';
import 'group_screen_test.dart' show openGroup;

/// The colour group's Presets tab: save, apply, rename, overwrite, delete,
/// kept on the phone.
void main() {
  Future<DemoApp> open(WidgetTester t) async {
    t.view.physicalSize = const Size(393, 2600);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final DemoApp d = await DemoApp.start(t, lights: DemoApp.groupLights);
    await DemoApp.settle(t, 1);
    openGroup(t, GroupKind.colour);
    await DemoApp.settle(t, 5);
    await t.tap(find.text('Presets'));
    await DemoApp.settle(t, 1);
    return d;
  }

  GroupSession groupOf(WidgetTester t) =>
      ProviderScope.containerOf(t.element(find.byType(GroupScreen)))
          .read(groupSessionProvider(GroupKind.colour))!;
  Finder slot(int i) => find.byKey(ValueKey<String>('group-preset-$i'));

  Future<void> name(WidgetTester t, String text) async {
    await t.enterText(find.byType(TextField), text);
    await t.tap(find.text('Save'));
    await DemoApp.settle(t, 1);
  }

  Future<void> menu(WidgetTester t, int i, String item) async {
    await t.longPress(slot(i));
    await DemoApp.settle(t, 1);
    await t.tap(find.text(item));
    await DemoApp.settle(t, 1);
  }

  testWidgets('15 slots; an empty one saves, a filled one applies and is '
      'marked; rename, overwrite and clear from the menu', (
    WidgetTester t,
  ) async {
    final DemoApp d = await open(t);
    final GroupSession group = groupOf(t);
    expect(find.byType(PresetSlotTile), findsNWidgets(GroupPresets.slots));
    // Make the lights follow the group, in two colours.
    await group.setBrightness(180);
    await group.setColour(const HsvIntent(Hsv(0, 1, 1)));
    await DemoApp.settle(t, 1);

    await t.tap(slot(0));
    await DemoApp.settle(t, 1);
    await name(t, 'Evening');
    expect(find.text('Preset saved'), findsOneWidget);
    expect(group.presets[0]!.name, 'Evening');
    expect(group.presets[0]!.lights, hasLength(3));
    expect(find.text('3 lights'), findsOneWidget);

    await group.setColour(const HsvIntent(Hsv(240, 1, 1)));
    await DemoApp.settle(t, 1);
    expect(d.twin('Desk strip').color.values, <int>[0, 0, 255]);
    await t.tap(slot(0));
    await DemoApp.settle(t, 2);
    expect(d.twin('Desk strip').color.values, <int>[255, 0, 0]);
    expect(group.activePreset, 0);
    expect(find.text('Current look: Evening'), findsOneWidget);
    expect(
      t.widget<PresetSlotTile>(find.byType(PresetSlotTile).first).active,
      isTrue,
    );

    await menu(t, 0, 'Rename');
    await name(t, 'Late');
    expect(group.presets[0]!.name, 'Late');
    expect(find.text('Late'), findsWidgets);

    // Overwrite with a new look keeps the name.
    await group.setColour(const HsvIntent(Hsv(120, 1, 1)));
    await DemoApp.settle(t, 1);
    await menu(t, 0, 'Overwrite with current look');
    expect(group.presets[0]!.name, 'Late');
    expect(group.presets[0]!.lights[d.id('Desk strip')]!.colour.values, <int>[
      0,
      255,
      0,
    ]);

    await menu(t, 0, 'Clear');
    expect(group.presets[0], isNull);
    expect(find.text('Current look: Late'), findsNothing);
    await DemoApp.shutDown(t);
  });

  testWidgets('a light away: "Saved 2 of 3 lights"', (WidgetTester t) async {
    final DemoApp d = await open(t);
    final GroupSession group = groupOf(t);
    await group.setBrightness(150);
    await DemoApp.settle(t, 1);
    d.radio.setAvailable('demo-rgbw-2', available: false);
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await DemoApp.settle(t, 3);
    await t.tap(slot(4));
    await DemoApp.settle(t, 1);
    await name(t, 'Most');
    expect(find.text('Saved 2 of 3 lights'), findsOneWidget);
    expect(group.presets[4]!.lights, hasLength(2));
    // The wheel is still there on the Colour tab.
    await t.tap(find.text('Colour'));
    await DemoApp.settle(t, 1);
    expect(find.byType(HueWheel), findsOneWidget);
    await DemoApp.shutDown(t);
  });
}
