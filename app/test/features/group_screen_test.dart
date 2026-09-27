import 'dart:async';

import 'package:electrobright/app/providers.dart';
import 'package:electrobright/core/color/colour_engine.dart';
import 'package:electrobright/core/model/channel_color.dart';
import 'package:electrobright/core/model/channel_layout.dart';
import 'package:electrobright/design/components/fixture_type.dart';
import 'package:electrobright/design/components/glass_controls.dart';
import 'package:electrobright/design/controls/glass_slider.dart';
import 'package:electrobright/design/controls/hue_wheel.dart';
import 'package:electrobright/design/glass/glass_surface.dart';
import 'package:electrobright/core/color/light_tone.dart';
import 'package:electrobright/core/protocol/eb/eb_scene.dart';
import 'package:electrobright/design/tone/tone_scope.dart';
import 'package:electrobright/features/control/colour/colour_editor.dart';
import 'package:electrobright/features/control/control_screen.dart';
import 'package:electrobright/features/control/shared/brightness_pill_slider.dart';
import 'package:electrobright/features/control/effects/effect_colours.dart';
import 'package:electrobright/features/groups/group_screen.dart';
import 'package:electrobright/l10n/app_localizations.dart';
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

  testWidgets('mixed shows the group\'s last master, never a value derived '
      'from the lights; after Rejoin all it is not mixed', (
    WidgetTester t,
  ) async {
    final DemoApp d = await open(t);
    double pill() =>
        t.widget<BrightnessPillSlider>(find.byType(BrightnessPillSlider)).value;
    // No master yet: "Mixed" over a full pill (the master every level is
    // relative to), never the lights' mean or half way.
    d.session('Desk strip').setBrightness(60, origin: CommandOrigin.system);
    await DemoApp.settle(t, 1);
    expect(find.text('Mixed'), findsOneWidget);
    expect(pill(), 1);

    final GroupSession group = groupOf(t);
    await group.setBrightness(200);
    await DemoApp.settle(t, 1);
    expect(find.text('Mixed'), findsNothing);
    expect(pill(), 200 / 255);
    // Lights that differ: still the master (not their mean, not half way).
    d.session('Desk strip').setBrightness(30, origin: CommandOrigin.system);
    d.session('Living room').setBrightness(90, origin: CommandOrigin.system);
    await DemoApp.settle(t, 1);
    expect(find.text('Mixed'), findsOneWidget);
    expect(pill(), 200 / 255);

    // A change on a light's own controls, then Rejoin all: it takes the
    // group's look, and nothing reads as mixed.
    d.session('Reading lamp').setBrightness(20);
    await DemoApp.settle(t, 1);
    await t.ensureVisible(find.byKey(const ValueKey<String>('rejoin-all')));
    await t.tap(find.byKey(const ValueKey<String>('rejoin-all')));
    await DemoApp.settle(t, 2);
    group.rejoin(d.id('Desk strip'));
    group.rejoin(d.id('Living room'));
    await DemoApp.settle(t, 2);
    for (final String n in colourLights) {
      expect(d.twin(n).brightness, 200, reason: n);
    }
    expect(find.text('Mixed'), findsNothing);
    expect(pill(), 200 / 255);
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

  /// A row's subtitle as read (the sun icon is U+FFFC).
  String subtitle(WidgetTester t, String id) => t
      .widget<Text>(find.byKey(ValueKey<String>('row-subtitle-$id')))
      .textSpan!
      .toPlainText();

  Future<void> tapRow(WidgetTester t, String id) async {
    final Finder row = find.byKey(ValueKey<String>('row-$id'));
    await t.ensureVisible(row);
    await t.tap(row);
    await DemoApp.settle(t, 1);
  }

  testWidgets('collapsed rows: one line of name, one of type and level; no '
      '"Connected", badge, level pill or Identify button', (
    WidgetTester t,
  ) async {
    final DemoApp d = await open(t);
    const Map<String, String> types = <String, String>{
      'Desk strip': 'RGB',
      'Living room': 'RGBW',
      'Reading lamp': 'RGBW',
    };
    for (final String n in colourLights) {
      final String id = d.id(n);
      final Finder row = find.byKey(ValueKey<String>('group-light-$id'));
      expect(t.getSize(row).height, lessThan(56), reason: n);
      expect(
        t
            .widget<Text>(find.descendant(of: row, matching: find.text(n)))
            .maxLines,
        1,
      );
      // One line each (two would be twice as tall).
      expect(t.getSize(find.text(n)).height, lessThan(28));
      expect(
        t.getSize(find.byKey(ValueKey<String>('row-subtitle-$id'))).height,
        lessThan(24),
      );
      expect(subtitle(t, id), '${types[n]} · \uFFFC 100 %');
      expect(
        t.getSize(find.byKey(ValueKey<String>('dot-$id'))),
        const Size(28, 28),
      );
      expect(find.byKey(ValueKey<String>('include-$id')), findsOneWidget);
      expect(find.byKey(ValueKey<String>('trim-$id')), findsNothing);
      expect(find.byKey(ValueKey<String>('flash-$id')), findsNothing);
      expect(find.byKey(ValueKey<String>('open-$id')), findsNothing);
    }
    final Finder list = find.ancestor(
      of: find.text('Lights in this group'),
      matching: find.byType(GlassSurface),
    );
    expect(
      find.descendant(of: list, matching: find.text('Connected')),
      findsNothing,
    );
    expect(
      find.descendant(of: list, matching: find.byType(FixtureTypeBadge)),
      findsNothing,
    );
    expect(
      find.descendant(of: list, matching: find.byType(Divider)),
      findsNWidgets(colourLights.length - 1),
    );
    await DemoApp.shutDown(t);
  });

  test('the subtitle states: connecting, unavailable, phone limit, own '
      'settings, excluded; none for a connected, following light', () {
    final AppLocalizations l = lookupAppLocalizations(const Locale('en'));
    String? of(
      LinkPhase phase, {
      bool included = true,
      bool own = false,
      bool limitedOut = false,
    }) => groupRowStatus(
      l,
      phase,
      included: included,
      own: own,
      limitedOut: limitedOut,
    );
    expect(of(LinkPhase.ready), isNull);
    for (final LinkPhase p in <LinkPhase>[
      LinkPhase.waiting,
      LinkPhase.connecting,
      LinkPhase.handshaking,
    ]) {
      expect(of(p), 'Connecting…');
    }
    expect(of(LinkPhase.unavailable), 'Unavailable');
    expect(of(LinkPhase.idle, limitedOut: true), 'Phone limit');
    expect(of(LinkPhase.ready, own: true), 'Own settings');
    expect(of(LinkPhase.idle, included: false), 'Excluded');
  });

  testWidgets('a light not connected: grey dot and its state in place of '
      'the level', (WidgetTester t) async {
    final DemoApp d = await open(t, lights: rgbRgbw, connect: false);
    final String id = d.id('Living room');
    expect(subtitle(t, id), anyOf('RGBW · Connecting…', 'RGBW · Unavailable'));
    final BoxDecoration dot =
        t
                .widget<Container>(
                  find.descendant(
                    of: find.byKey(ValueKey<String>('dot-$id')),
                    matching: find.byType(Container),
                  ),
                )
                .decoration!
            as BoxDecoration;
    expect(dot.color!.r, closeTo(dot.color!.g, 1e-6));
    expect(dot.color!.g, closeTo(dot.color!.b, 1e-6));
    await DemoApp.shutDown(t);
  });

  testWidgets('a tapped row opens its level and Flash, one row at a time; '
      'tapped again it closes', (WidgetTester t) async {
    final SemanticsHandle semantics = t.ensureSemantics();
    final DemoApp d = await open(t);
    final String a = d.id('Living room'), b = d.id('Reading lamp');
    final Finder rowA = find.byKey(ValueKey<String>('row-$a'));
    expect(
      t.getSemantics(rowA),
      matchesSemantics(
        label: 'Living room, RGBW, level 100 percent, following',
        hint: 'Double tap to expand',
        isButton: true,
        hasExpandedState: true,
        hasTapAction: true,
      ),
    );
    double turns(String id) => t
        .widget<AnimatedRotation>(
          find.descendant(
            of: find.byKey(ValueKey<String>('row-$id')),
            matching: find.byType(AnimatedRotation),
          ),
        )
        .turns;
    expect(turns(a), 0);
    await tapRow(t, a);
    expect(find.byKey(ValueKey<String>('trim-$a')), findsOneWidget);
    expect(find.byKey(ValueKey<String>('flash-$a')), findsOneWidget);
    expect(turns(a), 0.5);
    expect(
      t.getSemantics(rowA),
      matchesSemantics(
        label: 'Living room, RGBW, level 100 percent, following',
        hint: 'Double tap to collapse',
        isButton: true,
        hasExpandedState: true,
        isExpanded: true,
        hasTapAction: true,
      ),
    );
    expect(find.bySemanticsLabel('Flash Living room'), findsOneWidget);
    expect(
      find.bySemanticsLabel('Include Living room in the group'),
      findsOneWidget,
    );
    await tapRow(t, b);
    expect(find.byKey(ValueKey<String>('trim-$a')), findsNothing);
    expect(find.byKey(ValueKey<String>('trim-$b')), findsOneWidget);
    expect(turns(a), 0);
    await tapRow(t, b);
    expect(find.byKey(ValueKey<String>('trim-$b')), findsNothing);
    expect(find.byKey(ValueKey<String>('flash-$b')), findsNothing);
    semantics.dispose();
    await DemoApp.shutDown(t);
  });

  testWidgets('Flash flashes only its own light; only this group\'s lights '
      'are listed', (WidgetTester t) async {
    final DemoApp d = await open(t);
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
    // The light's own IDENTIFY flashes; its twin's never do.
    final Set<bool?> a = <bool?>{}, b = <bool?>{};
    final Set<int> levels = <int>{};
    await tapRow(t, d.id('Living room'));
    final Finder button = find.byKey(
      ValueKey<String>('flash-${d.id('Living room')}'),
    );
    await t.ensureVisible(button);
    await t.tap(button);
    for (int i = 0; i < 60; i++) {
      await t.pump(const Duration(milliseconds: 25));
      a.add(d.model('Living room').identifyFlash);
      b.add(d.model('Reading lamp').identifyFlash);
      levels.add(d.twin('Living room').brightness);
    }
    expect(a, containsAll(<bool>[true, false]));
    expect(b, <bool?>{null});
    expect(levels, hasLength(1), reason: 'the level itself never changes');
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
    expect(subtitle(t, d.id('Reading lamp')), 'RGBW · Excluded');
    final SemanticsHandle semantics = t.ensureSemantics();
    expect(
      t
          .getSemantics(
            find.byKey(ValueKey<String>('row-${d.id('Reading lamp')}')),
          )
          .label,
      'Reading lamp, RGBW, level 100 percent, excluded',
    );
    semantics.dispose();
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
    await tapRow(t, d.id('Living room'));
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
    await tapRow(t, d.id('Living room'));
    expect(
      subtitle(t, d.id('Living room')),
      'RGBW · \uFFFC ${(level * 100).round()} %',
    );
    await DemoApp.shutDown(t);
  });

  testWidgets('a drag on the open slider moves only that light, live', (
    WidgetTester t,
  ) async {
    final DemoApp d = await open(t);
    final String id = d.id('Reading lamp');
    await tapRow(t, id);
    final Finder trim = find.byKey(ValueKey<String>('trim-$id'));
    final int other = d.twin('Living room').brightness;
    final Rect r = t.getRect(trim);
    final TestGesture g = await t.startGesture(
      Offset(r.right - 4, r.center.dy),
    );
    final List<int> seen = <int>[];
    for (int i = 0; i < 3; i++) {
      await g.moveBy(Offset(-r.width * 0.2, 0));
      await DemoApp.settle(t, 1);
      seen.add(d.twin('Reading lamp').brightness);
      expect(d.twin('Living room').brightness, other);
    }
    // It follows the finger before the release, and is saved only then.
    expect(seen.first, lessThan(255));
    expect(seen, orderedEquals(<int>[...seen]..sort((int a, int b) => b - a)));
    expect(seen.toSet().length, 3);
    expect(groupOf(t).trimOf(id), 1);
    await g.up();
    await DemoApp.settle(t, 1);
    expect(groupOf(t).trimOf(id), lessThan(1));
    expect(d.twin('Reading lamp').brightness, lessThan(seen.first));
    expect(d.twin('Living room').brightness, other);
    expect(groupOf(t).isOwn(id), isFalse);
    await DemoApp.shutDown(t);
  });

  testWidgets('colour group, Police: colour source and beacons for every '
      'light, mixed while they differ; the white group has none', (
    WidgetTester t,
  ) async {
    final DemoApp d = await open(t);
    await t.tap(find.text('Effects'));
    await DemoApp.settle(t, 1);
    await t.tap(find.byKey(const ValueKey<String>('mode-12')));
    await DemoApp.settle(t, 2);
    final Finder source = find.byKey(
      const ValueKey<String>('group-colour-source'),
    );
    expect(source, findsOneWidget);
    // Police starts on its own red/blue: no beacons.
    expect(find.byType(BeaconSwatch), findsNothing);
    await t.ensureVisible(source);
    await t.tap(
      find.descendant(of: source, matching: find.text('Your colours')),
    );
    await DemoApp.settle(t, 2);
    for (final String n in colourLights) {
      expect(d.twin(n).policeColorMode, 0, reason: n);
    }
    expect(find.byType(BeaconSwatch), findsNWidgets(2));
    // One light's beacon on its own: split swatch until the group sets it.
    unawaited(
      d
          .session('Living room')
          .setPoliceColor(
            EbPoliceSlot.a,
            ChannelColor(ChannelLayout.rgbw, const <int>[0, 0, 255, 0]),
            origin: CommandOrigin.system,
          ),
    );
    await DemoApp.settle(t, 1);
    expect(
      t
          .widget<BeaconSwatch>(
            find.byKey(const ValueKey<String>('group-beacon-a')),
          )
          .color,
      isNull,
    );
    await groupOf(t)
        .setPoliceColor(EbPoliceSlot.a, const HsvIntent(Hsv(120, 1, 1)));
    await DemoApp.settle(t, 1);
    expect(
      t
          .widget<BeaconSwatch>(
            find.byKey(const ValueKey<String>('group-beacon-a')),
          )
          .color,
      isNotNull,
    );
    for (final String n in colourLights) {
      expect(d.twin(n).policeA.values.take(3), <int>[0, 255, 0], reason: n);
    }
    // A colour source that differs shows no choice.
    unawaited(
      d
          .session('Desk strip')
          .setColorMode(
            EbColorModeKind.police,
            1,
            origin: CommandOrigin.system,
          ),
    );
    await DemoApp.settle(t, 1);
    expect(
      t
          .widget<GlassSegmented<int?>>(
            find.descendant(
              of: source,
              matching: find.byType(GlassSegmented<int?>),
            ),
          )
          .selected,
      isNull,
    );
    await DemoApp.shutDown(t);
  });

  testWidgets('white group, Police: no colour source', (WidgetTester t) async {
    await open(t, lights: cctW, kind: GroupKind.white);
    await t.tap(find.text('Effects'));
    await DemoApp.settle(t, 1);
    await t.tap(find.byKey(const ValueKey<String>('mode-12')));
    await DemoApp.settle(t, 2);
    expect(
      find.byKey(const ValueKey<String>('group-colour-source')),
      findsNothing,
    );
    expect(find.byType(ColourSourceControl), findsNothing);
    await DemoApp.shutDown(t);
  });

  testWidgets('the white group\'s tone is a CCT light\'s at the same '
      'temperature', (WidgetTester t) async {
    // Tones land at once (no glide) to compare them.
    t.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(t.platformDispatcher.clearAllTestValues);
    final DemoApp d = await open(t, lights: cctOnly, kind: GroupKind.white);
    await groupOf(t).setTemperature(3000);
    await DemoApp.settle(t, 2);
    final LightTone group = ToneScope.of(t.element(find.byType(KelvinSlider)));
    // Back to Home, then the same temperature on one light's own screen.
    await t.tap(find.byIcon(Icons.chevron_left_rounded).first);
    await DemoApp.settle(t, 2);
    await d.open(t, 'Kitchen');
    await DemoApp.settle(t, 1);
    final LightTone single = ToneScope.of(t.element(find.byType(KelvinSlider)));
    expect(group, single);
    await DemoApp.shutDown(t);
  });

  testWidgets('a W-only group\'s tone is a W light\'s', (WidgetTester t) async {
    // Tones land at once (no glide) to compare them.
    t.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(t.platformDispatcher.clearAllTestValues);
    final DemoApp d = await open(t, lights: wOnly, kind: GroupKind.white);
    final LightTone group = ToneScope.of(
      t.element(find.byKey(const ValueKey<String>('effects-grid'))),
    );
    await t.tap(find.byIcon(Icons.chevron_left_rounded).first);
    await DemoApp.settle(t, 2);
    await d.open(t, 'Hallway');
    await DemoApp.settle(t, 1);
    final LightTone single = ToneScope.of(
      t.element(
        find.descendant(
          of: find.byType(ControlScreen),
          matching: find.byKey(const ValueKey<String>('brightness')),
        ),
      ),
    );
    expect(group, single);
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
    expect(subtitle(t, d.id('Living room')), 'RGBW · Own settings');
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
