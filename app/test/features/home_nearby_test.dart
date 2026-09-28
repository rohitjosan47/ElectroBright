import 'package:electrobright/app/providers.dart';
import 'package:electrobright/core/model/channel_layout.dart';
import 'package:electrobright/core/model/fixture.dart';
import 'package:electrobright/features/add_fixture/add_light_screen.dart';
import 'package:electrobright/features/home/home_screen.dart';
import 'package:electrobright/sim/sim_central.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/demo_app.dart';

/// Home never lists nearby lights: the ones that can be added show as a
/// count on "Add light" (not saved, not legacy, not hidden as "Not mine";
/// heard in the last 10 s).
void main() {
  Future<DemoApp> tall(WidgetTester t, {int extra = 0}) async {
    // Tall enough for every light (a list would show below them).
    t.view.physicalSize = const Size(393, 2400);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final DemoApp d = await DemoApp.start(t);
    // Lights nearby, not added (the demo's own are all saved).
    for (int i = 1; i <= extra; i++) {
      d.radio.fixtures.add(SimFixture.electroBright(id: 'demo-extra-$i'));
    }
    await DemoApp.settle(t, 3);
    return d;
  }

  ProviderContainer container(WidgetTester t) => ProviderScope.containerOf(
    t.element(find.byType(HomeScreen)),
    listen: false,
  );

  /// The count on "Add light", or null when it has none.
  int? badge(WidgetTester t) {
    final Badge b = t.widget<Badge>(
      find.ancestor(
        of: find.byType(FloatingActionButton),
        matching: find.byType(Badge),
      ),
    );
    if (!b.isLabelVisible) return null;
    return int.parse(((b.label! as ExcludeSemantics).child! as Text).data!);
  }

  void expectHomeListsNoNearby() {
    expect(find.byType(NearbyRow, skipOffstage: false), findsNothing);
    expect(find.text('Nearby — not added'), findsNothing);
    expect(find.text('Unsupported lights'), findsNothing);
    expect(find.text('Update needed'), findsNothing);
  }

  testWidgets('the badge counts the lights that can be added; legacy and '
      'saved lights never count, and Home never lists them', (
    WidgetTester t,
  ) async {
    final DemoApp d = await tall(t, extra: 2);
    expect(
      d.radio.fixtures.any((SimFixture f) => f.id == 'demo-legacy'),
      isTrue,
    );
    expect(badge(t), 2);
    final SemanticsHandle semantics = t.ensureSemantics();
    expect(
      find.bySemanticsLabel(RegExp(r'^Add light, 2 lights nearby$')),
      findsOneWidget,
    );
    semantics.dispose();
    expectHomeListsNoNearby();
    // Five saved, Home keeps three connected.
    expect(find.text('3 of 5 connected'), findsOneWidget);
    expect(find.textContaining('nearby'), findsNothing);
    await DemoApp.shutDown(t);
  });

  testWidgets('no badge at 0; one light: "1 light nearby"', (
    WidgetTester t,
  ) async {
    final DemoApp d = await tall(t);
    // Only the legacy light is unsaved: no badge.
    expect(badge(t), isNull);
    final SemanticsHandle semantics = t.ensureSemantics();
    expect(find.bySemanticsLabel(RegExp(r'^Add light$')), findsOneWidget);
    expectHomeListsNoNearby();

    d.radio.fixtures.add(SimFixture.electroBright(id: 'demo-extra-1'));
    await DemoApp.settle(t, 2);
    expect(badge(t), 1);
    expect(
      find.bySemanticsLabel(RegExp(r'^Add light, 1 light nearby$')),
      findsOneWidget,
    );
    semantics.dispose();
    await DemoApp.shutDown(t);
  });

  testWidgets('a light switched off leaves the count 10 s after its last '
      'advert, not before; back on, it counts at once', (WidgetTester t) async {
    final DemoApp d = await tall(t, extra: 1);
    expect(badge(t), 1);
    d.radio.setAvailable('demo-extra-1', available: false);
    await DemoApp.settle(t, 9);
    expect(badge(t), 1, reason: 'no flicker');
    await DemoApp.settle(t, 2);
    expect(badge(t), isNull);
    d.radio.setAvailable('demo-extra-1', available: true);
    await DemoApp.settle(t, 1);
    expect(badge(t), 1);
    await DemoApp.shutDown(t);
  });

  testWidgets('hidden lights never count; saving a light drops it', (
    WidgetTester t,
  ) async {
    final DemoApp d = await tall(t, extra: 2);
    expect(badge(t), 2);
    final ProviderContainer c = container(t);
    c.read(hiddenLightsProvider.notifier).hide('demo-extra-1');
    await t.pump();
    expect(badge(t), 1);
    c.read(hiddenLightsProvider.notifier).showAll();
    await t.pump();
    expect(badge(t), 2);
    // A light the user adds is no longer "nearby".
    d.app.registry.add(
      Fixture(
        id: 'f-demo-extra-2',
        deviceId: 'demo-extra-2',
        name: 'Porch',
        layout: ChannelLayout.rgbw,
        driver: DriverKind.electroBright,
        addedAt: DateTime(2026),
      ),
    );
    await DemoApp.settle(t, 1);
    expect(badge(t), 1);
    await DemoApp.shutDown(t);
  });

  testWidgets('RSSI changes do not rebuild Home; a new light does', (
    WidgetTester t,
  ) async {
    final DemoApp d = await tall(t, extra: 1);
    final SimFixture extra = d.radio.fixtures.firstWhere(
      (SimFixture f) => f.id == 'demo-extra-1',
    );
    int builds = 0;
    debugOnRebuildDirtyWidget = (Element e, bool _) {
      if (e.widget is HomeScreen) builds++;
    };
    addTearDown(() => debugOnRebuildDirtyWidget = null);

    // A wobble, then a new bar: the count is the same.
    extra.rssi = -63;
    await DemoApp.settle(t, 3);
    extra.rssi = -45;
    await DemoApp.settle(t, 3);
    expect(builds, 0);

    d.radio.fixtures.add(SimFixture.electroBright(id: 'demo-extra-2'));
    await DemoApp.settle(t, 2);
    expect(builds, greaterThan(0));
    expect(badge(t), 2);

    debugOnRebuildDirtyWidget = null;
    await DemoApp.shutDown(t);
  });
}
