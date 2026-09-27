import 'dart:async';

import 'package:electrobright/app/providers.dart';
import 'package:electrobright/core/color/colour_engine.dart';
import 'package:electrobright/core/model/channel_color.dart';
import 'package:electrobright/core/model/channel_layout.dart';
import 'package:electrobright/design/components/glass_controls.dart';
import 'package:electrobright/design/controls/glass_slider.dart';
import 'package:electrobright/design/controls/hue_wheel.dart';
import 'package:electrobright/features/control/colour/colour_editor.dart';
import 'package:electrobright/features/groups/group_screen.dart';
import 'package:electrobright/sessions/fixture_session.dart';
import 'package:electrobright/sessions/group_capabilities.dart';
import 'package:electrobright/sessions/group_session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/demo_app.dart';

/// The group screens (simulated lights): the colour group of an RGB and two
/// identical RGBW lights; the white group in its three mixes; the lights
/// list with trims, own settings and the way back.
void main() {
  const List<String> colourLights = <String>[
    'Desk strip',
    'Living room',
    'Reading lamp',
  ];
  const Map<String, (String, ChannelLayout)> cctW =
      <String, (String, ChannelLayout)>{
        'Kitchen': ('demo-cct', ChannelLayout.cct),
        'Hallway': ('demo-w', ChannelLayout.w),
      };
  const Map<String, (String, ChannelLayout)> cctOnly =
      <String, (String, ChannelLayout)>{
        'Kitchen': ('demo-cct', ChannelLayout.cct),
        'Pantry': ('demo-cct-2', ChannelLayout.cct),
      };
  const Map<String, (String, ChannelLayout)> wOnly =
      <String, (String, ChannelLayout)>{
        'Hallway': ('demo-w', ChannelLayout.w),
        'Porch': ('demo-w-2', ChannelLayout.w),
      };
  const Map<String, (String, ChannelLayout)> rgbRgbw =
      <String, (String, ChannelLayout)>{
        'Desk strip': ('demo-rgb', ChannelLayout.rgb),
        'Living room': ('demo-rgbw', ChannelLayout.rgbw),
      };
  const int rainbow = 10;

  Future<DemoApp> open(
    WidgetTester t, {
    Map<String, (String, ChannelLayout)> lights = DemoApp.groupLights,
    GroupKind kind = GroupKind.colour,
    bool connect = true,
  }) async {
    t.view.physicalSize = const Size(393, 2600);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final DemoApp d = await DemoApp.start(t, lights: lights);
    await DemoApp.settle(t, 1);
    if (!connect) {
      for (final (String dev, ChannelLayout _) in lights.values) {
        d.radio.setAvailable(dev, available: false);
      }
      d.radio.setAvailable('demo-legacy', available: false);
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await DemoApp.settle(t, 2);
    }
    openGroup(t, kind);
    await DemoApp.settle(t, 5);
    expect(find.byType(GroupScreen), findsOneWidget);
    return d;
  }

  GroupSession groupOf(WidgetTester t) =>
      ProviderScope.containerOf(t.element(find.byType(GroupScreen))).read(
        groupSessionProvider(
          t.widget<GroupScreen>(find.byType(GroupScreen)).kind,
        ),
      )!;

  Finder slider(String label) => find.byWidgetPredicate(
    (Widget w) => w is GlassSlider && w.semanticLabel == label,
  );
  final Finder tabs = find.byWidgetPredicate(
    (Widget w) => w.runtimeType.toString() == 'GlassSegmented<_GroupTab>',
  );
  List<String> tabLabels(WidgetTester t) => <String>[
    for (final Element e
        in find.descendant(of: tabs, matching: find.byType(Text)).evaluate())
      (e.widget as Text).data!,
  ];

  /// Sends a colour as the editor does (its intent output).
  Future<void> pick(WidgetTester t, ColourIntent intent) async {
    final ColourEditor editor = t.widget<ColourEditor>(
      find.byType(ColourEditor),
    );
    editor.onChanged(
      const ColourEngine().encode(intent, editor.value.layout),
      live: false,
      intent: intent,
    );
    await DemoApp.settle(t, 1);
  }

  // ---- per group ---------------------------------------------------------------------

  testWidgets('colour group: Colour | Effects | Presets, the wheel alone; a '
      'pick reaches every light with its white LED off', (
    WidgetTester t,
  ) async {
    final DemoApp d = await open(t);
    expect(find.text('Colour lights'), findsOneWidget);
    expect(find.text('3 of 3 connected'), findsOneWidget);
    expect(tabLabels(t), <String>['Colour', 'Effects', 'Presets']);
    expect(find.byType(HueWheel), findsOneWidget);
    expect(
      t.widget<ColourEditor>(find.byType(ColourEditor)).showChannels,
      isFalse,
    );
    expect(
      t.widget<ColourEditor>(find.byType(ColourEditor)).value.layout,
      ChannelLayout.rgb,
    );
    expect(slider('White LED'), findsNothing);
    expect(slider('Colour temperature'), findsNothing);
    expect(
      find.descendant(
        of: find.byType(ColourEditor),
        matching: find.byWidgetPredicate((Widget w) => w is GlassSegmented),
      ),
      findsNothing,
    );
    // Lights keep a white LED lit until the group picks a colour.
    d
        .session('Living room')
        .setColor(
          ChannelColor(ChannelLayout.rgbw, const <int>[0, 0, 0, 200]),
          origin: CommandOrigin.system,
        );
    await DemoApp.settle(t, 1);
    const HsvIntent red = HsvIntent(Hsv(0, 1, 1));
    await pick(t, red);
    expect(d.twin('Desk strip').color.values, <int>[255, 0, 0]);
    for (final String n in <String>['Living room', 'Reading lamp']) {
      expect(d.twin(n).color.values, <int>[255, 0, 0, 0], reason: n);
      expect(d.session(n).status.colourPick?.intent, red, reason: n);
    }
    await DemoApp.shutDown(t);
  });

  testWidgets('white group, CCT + W: White | Effects | Presets, the '
      'temperature alone and the W caption', (WidgetTester t) async {
    final DemoApp d = await open(t, lights: cctW, kind: GroupKind.white);
    expect(find.text('White lights'), findsOneWidget);
    expect(tabLabels(t), <String>['White', 'Effects', 'Presets']);
    expect(find.byType(KelvinSlider), findsOneWidget);
    expect(find.byType(ColourEditor), findsNothing);
    expect(find.byType(HueWheel), findsNothing);
    expect(slider('Level'), findsNothing);
    expect(find.text('W lights keep their white'), findsOneWidget);
    final ChannelColor hallway = d.twin('Hallway').color;
    final KelvinSlider k = t.widget<KelvinSlider>(find.byType(KelvinSlider));
    k.onChangeStart!();
    k.onChanged(3000);
    k.onChangeEnd!(3000);
    await DemoApp.settle(t, 1);
    expect(
      d.session('Kitchen').status.colourPick?.intent,
      const WhiteIntent(3000, 1),
    );
    expect(d.twin('Hallway').color, hallway);
    expect(find.text('3000 K'), findsOneWidget);
    await DemoApp.shutDown(t);
  });

  testWidgets('white group, CCT only: no caption', (WidgetTester t) async {
    await open(t, lights: cctOnly, kind: GroupKind.white);
    expect(tabLabels(t), <String>['White', 'Effects', 'Presets']);
    expect(find.byType(KelvinSlider), findsOneWidget);
    expect(find.text('W lights keep their white'), findsNothing);
    await DemoApp.shutDown(t);
  });

  testWidgets('white group, W only: Effects | Presets', (WidgetTester t) async {
    await open(t, lights: wOnly, kind: GroupKind.white);
    expect(find.text('2 of 2 connected'), findsOneWidget);
    expect(tabLabels(t), <String>['Effects', 'Presets']);
    expect(find.byType(KelvinSlider), findsNothing);
    expect(find.byType(ColourEditor), findsNothing);
    expect(find.byKey(const ValueKey<String>('effects-grid')), findsOneWidget);
    await DemoApp.shutDown(t);
  });

  testWidgets('Rainbow shows how many lights have it and goes to those', (
    WidgetTester t,
  ) async {
    final DemoApp d = await open(t, kind: GroupKind.white);
    // The white group of DemoApp.groupLights: tunable white and single
    // white. The single white has no Rainbow.
    expect(tabLabels(t), <String>['White', 'Effects', 'Presets']);
    await t.tap(find.text('Effects'));
    await DemoApp.settle(t, 1);
    expect(find.text('1/2'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey<String>('mode-$rainbow')));
    await DemoApp.settle(t, 2);
    expect(d.twin('Kitchen').mode, rainbow);
    expect(d.twin('Hallway').mode, 1);
    expect(find.text('Applied to 1 of 2 lights'), findsOneWidget);
    await DemoApp.shutDown(t);
  });

  // ---- shared controls ---------------------------------------------------------------

  testWidgets('mixed brightness says so; the first drag sets every light', (
    WidgetTester t,
  ) async {
    final DemoApp d = await open(t);
    d.session('Desk strip').setBrightness(60, origin: CommandOrigin.system);
    await DemoApp.settle(t, 1);
    expect(find.text('Mixed'), findsOneWidget);
    await t.drag(
      find.byKey(const ValueKey<String>('brightness')),
      const Offset(-60, 0),
    );
    await DemoApp.settle(t, 1);
    expect(find.text('Mixed'), findsNothing);
    final int b = d.twin('Desk strip').brightness;
    expect(b, isNot(60));
    for (final String n in colourLights) {
      expect(d.twin(n).brightness, b, reason: n);
    }
    await DemoApp.shutDown(t);
  });

  testWidgets('the sleep timer starts and is cancelled on every light', (
    WidgetTester t,
  ) async {
    final DemoApp d = await open(t);
    await t.tap(find.byKey(const ValueKey<String>('timer-button')));
    await DemoApp.settle(t, 1);
    await t.tap(find.byKey(const ValueKey<String>('timer-start')));
    await DemoApp.settle(t, 2);
    for (final String n in colourLights) {
      expect(d.model(n).timerActive, isTrue, reason: n);
    }
    expect(find.byKey(const ValueKey<String>('timer-left')), findsOneWidget);
    await t.tap(find.byKey(const ValueKey<String>('timer-button')));
    await DemoApp.settle(t, 1);
    await t.tap(find.byKey(const ValueKey<String>('timer-cancel')));
    await DemoApp.settle(t, 2);
    for (final String n in colourLights) {
      expect(d.model(n).timerActive, isFalse, reason: n);
    }
    await DemoApp.shutDown(t);
  });

  // ---- the lights list ---------------------------------------------------------------

  testWidgets('rows: type, Identify and the include switch, no way to the '
      'light\'s own screen; Identify flashes only its own light', (
    WidgetTester t,
  ) async {
    final DemoApp d = await open(t);
    for (final String n in colourLights) {
      expect(find.byKey(ValueKey<String>('open-${d.id(n)}')), findsNothing);
      expect(
        find.byKey(ValueKey<String>('identify-${d.id(n)}')),
        findsOneWidget,
      );
      expect(
        find.byKey(ValueKey<String>('include-${d.id(n)}')),
        findsOneWidget,
      );
    }
    // Only this group's lights are listed.
    expect(
      find.byKey(ValueKey<String>('group-light-${d.id('Kitchen')}')),
      findsNothing,
    );
    expect(
      find.descendant(
        of: find.byKey(ValueKey<String>('group-light-${d.id('Living room')}')),
        matching: find.byIcon(Icons.chevron_right_rounded),
      ),
      findsNothing,
    );
    final Set<int> a = <int>{}, b = <int>{};
    final Finder button = find.byKey(
      ValueKey<String>('identify-${d.id('Living room')}'),
    );
    await t.ensureVisible(button);
    await t.tap(button);
    for (int i = 0; i < 60; i++) {
      await t.pump(const Duration(milliseconds: 25));
      a.add(d.twin('Living room').brightness);
      b.add(d.twin('Reading lamp').brightness);
    }
    expect(a, contains(0));
    expect(b, hasLength(1));
    await DemoApp.shutDown(t);
  });

  testWidgets('leaving out one RGBW light leaves its twin working', (
    WidgetTester t,
  ) async {
    final DemoApp d = await open(t);
    final Finder include = find.byKey(
      ValueKey<String>('include-${d.id('Reading lamp')}'),
    );
    await t.ensureVisible(include);
    await t.tap(include);
    await DemoApp.settle(t, 1);
    expect(find.text('2 of 3 connected'), findsOneWidget);
    expect(find.textContaining('Excluded'), findsOneWidget);
    final ChannelColor before = d.twin('Reading lamp').color;
    await pick(t, const HsvIntent(Hsv(120, 1, 1)));
    expect(d.twin('Living room').color.values, <int>[0, 255, 0, 0]);
    expect(d.twin('Reading lamp').color, before);
    await DemoApp.shutDown(t);
  });

  testWidgets('a light\'s level in the group changes only that light', (
    WidgetTester t,
  ) async {
    final DemoApp d = await open(t);
    final int twinBefore = d.twin('Reading lamp').brightness;
    final Finder row = find.byKey(
      ValueKey<String>('row-${d.id('Living room')}'),
    );
    await t.ensureVisible(row);
    await t.tap(row);
    await DemoApp.settle(t, 1);
    final Finder trim = find.byKey(
      ValueKey<String>('trim-${d.id('Living room')}'),
    );
    expect(trim, findsOneWidget);
    final Rect r = t.getRect(trim);
    await t.tapAt(Offset(r.left + r.width * 0.5, r.center.dy));
    await DemoApp.settle(t, 1);
    final double level = groupOf(t).trimOf(d.id('Living room'));
    expect(level, inInclusiveRange(0.4, 0.6));
    expect(d.twin('Living room').brightness, (255 * level).round());
    expect(d.twin('Reading lamp').brightness, twinBefore);
    expect(groupOf(t).isOwn(d.id('Living room')), isFalse);
    await t.tap(row);
    await DemoApp.settle(t, 1);
    expect(
      find.byKey(ValueKey<String>('trim-chip-${d.id('Living room')}')),
      findsOneWidget,
    );
    await DemoApp.shutDown(t);
  });

  testWidgets('a change on the light\'s own controls: "Own settings", skipped '
      'by the group, back with Rejoin all', (WidgetTester t) async {
    final DemoApp d = await open(t);
    final GroupSession group = groupOf(t);
    await group.setBrightness(200);
    await DemoApp.settle(t, 1);
    // The user on the light's own screen (or its Home tile).
    d.session('Living room').setBrightness(90);
    await DemoApp.settle(t, 1);
    expect(find.textContaining('Own settings'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('rejoin-all')), findsOneWidget);
    unawaited(group.setMode(3));
    await DemoApp.settle(t, 2);
    expect(d.twin('Living room').mode, isNot(3));
    expect(d.twin('Reading lamp').mode, 3);
    await t.ensureVisible(find.byKey(const ValueKey<String>('rejoin-all')));
    await t.tap(find.byKey(const ValueKey<String>('rejoin-all')));
    await DemoApp.settle(t, 2);
    expect(find.textContaining('Own settings'), findsNothing);
    expect(d.twin('Living room').mode, 3);
    await DemoApp.shutDown(t);
  });

  testWidgets('no light following: a message and one way back', (
    WidgetTester t,
  ) async {
    final DemoApp d = await open(t, lights: cctW, kind: GroupKind.white);
    final GroupSession group = groupOf(t);
    for (final String n in cctW.keys) {
      group.setExcluded(d.id(n), excluded: true);
    }
    await DemoApp.settle(t, 1);
    expect(
      find.byKey(const ValueKey<String>('group-none-following')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey<String>('brightness')), findsNothing);
    await t.tap(find.text('Include lights'));
    await DemoApp.settle(t, 2);
    expect(find.byKey(const ValueKey<String>('brightness')), findsOneWidget);
    await DemoApp.shutDown(t);
  });

  testWidgets('no light connected: controls off, and it says so', (
    WidgetTester t,
  ) async {
    await open(t, lights: rgbRgbw, connect: false);
    expect(find.textContaining('No lights connected'), findsOneWidget);
    expect(
      t
          .widget<GlassSlider>(find.byKey(const ValueKey<String>('brightness')))
          .enabled,
      isFalse,
    );
    await DemoApp.shutDown(t);
  });
}

/// Opens a group over Home.
void openGroup(WidgetTester t, GroupKind kind) => unawaited(
  t
      .state<NavigatorState>(find.byType(Navigator).first)
      .push(MaterialPageRoute<void>(builder: (_) => GroupScreen(kind: kind))),
);
