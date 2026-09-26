import 'package:electrobright/app/providers.dart';
import 'package:electrobright/features/add_fixture/add_light_screen.dart';
import 'package:electrobright/features/control/control_screen.dart';
import 'package:electrobright/features/home/home_screen.dart';
import 'package:electrobright/sessions/discovery.dart';
import 'package:electrobright/sim/sim_central.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/demo_app.dart';

/// Home hears of a nearby light's adverts only when what it shows changes
/// (the lights, their order, names, types, signal bars), not on every RSSI
/// wobble.
void main() {
  testWidgets('an RSSI wobble does not rebuild Home; a new bar does', (
    WidgetTester t,
  ) async {
    final DemoApp d = await DemoApp.start(t);
    await DemoApp.settle(t, 3);
    final ProviderContainer c = ProviderScope.containerOf(
      t.element(find.byType(HomeScreen)),
      listen: false,
    );
    final SimFixture legacy = d.radio.fixtures.firstWhere(
      (SimFixture f) => f.id == 'demo-legacy',
    );
    int bars() => c
        .read(nearbyProvider)
        .firstWhere((NearbyLight n) => n.seen.id == legacy.id)
        .seen
        .signalBars;
    expect(bars(), 3);

    int builds = 0;
    debugOnRebuildDirtyWidget = (Element e, bool _) {
      if (e.widget is HomeScreen) builds++;
    };
    addTearDown(() => debugOnRebuildDirtyWidget = null);

    // Still three bars: nothing Home shows changes.
    legacy.rssi = -63;
    await DemoApp.settle(t, 3);
    expect(builds, 0);
    expect(bars(), 3);

    // Four bars: Home rebuilds and shows them.
    legacy.rssi = -45;
    await DemoApp.settle(t, 3);
    expect(builds, greaterThan(0));
    expect(bars(), 4);

    debugOnRebuildDirtyWidget = null;
    await DemoApp.shutDown(t);
  });

  testWidgets('the fast scan runs only while Home is on screen', (
    WidgetTester t,
  ) async {
    // Tall enough for every light and the nearby list.
    t.view.physicalSize = const Size(393, 2400);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final DemoApp d = await DemoApp.start(t);
    await DemoApp.settle(t, 3);
    final Discovery discovery = d.app.ble.discovery;
    expect(discovery.strongestNeed, ScanNeed.addFlow);
    expect(discovery.isScanning, isTrue);
    final int rows = find.byType(NearbyRow).evaluate().length;
    expect(rows, greaterThan(0));

    // Opening a light: the list stays on Home through the transition, and
    // the scan stops once Home is covered.
    await t.scrollUntilVisible(
      find.text('Living room'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await t.tap(find.text('Living room'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 150));
    expect(find.byType(NearbyRow, skipOffstage: false).evaluate().length, rows);
    expect(discovery.strongestNeed, ScanNeed.addFlow);
    await DemoApp.settle(t, 2);
    expect(find.byType(ControlScreen), findsOneWidget);
    expect(discovery.strongestNeed, isNot(ScanNeed.addFlow));

    // Back on Home it runs again, the list as it was.
    Navigator.of(t.element(find.byType(ControlScreen))).pop();
    await t.pump();
    expect(discovery.strongestNeed, ScanNeed.addFlow);
    await DemoApp.settle(t, 2);
    expect(find.byType(NearbyRow).evaluate().length, rows);

    // In the background nothing scans; back in the foreground it resumes.
    for (final AppLifecycleState s in <AppLifecycleState>[
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ]) {
      t.binding.handleAppLifecycleStateChanged(s);
    }
    await t.pump();
    expect(discovery.isScanning, isFalse);
    for (final AppLifecycleState s in <AppLifecycleState>[
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      t.binding.handleAppLifecycleStateChanged(s);
    }
    await t.pump();
    expect(discovery.isScanning, isTrue);
    expect(discovery.strongestNeed, ScanNeed.addFlow);
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await DemoApp.settle(t, 10);
    await DemoApp.shutDown(t);
  });

  testWidgets('a nearby light gone for 2 minutes leaves the list', (
    WidgetTester t,
  ) async {
    t.view.physicalSize = const Size(393, 2400);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final DemoApp d = await DemoApp.start(t);
    await DemoApp.settle(t, 3);
    expect(find.byType(NearbyRow), findsOneWidget);
    d.radio.setAvailable('demo-legacy', available: false);
    await DemoApp.settle(t, 100);
    expect(find.byType(NearbyRow), findsOneWidget);
    await DemoApp.settle(t, 35);
    expect(find.byType(NearbyRow), findsNothing);
    // Back again, it's listed again.
    d.radio.setAvailable('demo-legacy', available: true);
    await DemoApp.settle(t, 2);
    expect(find.byType(NearbyRow), findsOneWidget);
    await DemoApp.shutDown(t);
  });
}
