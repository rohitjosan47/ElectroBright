import 'package:electrobright/app/providers.dart';
import 'package:electrobright/features/add_fixture/add_light_screen.dart';
import 'package:electrobright/features/control/control_screen.dart';
import 'package:electrobright/features/firmware_update/firmware_update_screen.dart';
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

  Future<DemoApp> tall(WidgetTester t) async {
    t.view.physicalSize = const Size(393, 2400);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final DemoApp d = await DemoApp.start(t);
    // One more light nearby, not added (the demo's own are all saved).
    d.radio.fixtures.add(SimFixture.electroBright(id: 'demo-extra'));
    await DemoApp.settle(t, 3);
    return d;
  }

  Finder rowOf(String deviceId) => find.byWidgetPredicate(
    (Widget w) => w is NearbyRow && w.light.seen.id == deviceId,
  );

  testWidgets('a nearby light switched off leaves the list 10 s after its '
      'last advert, not before; back on, it is listed at once', (
    WidgetTester t,
  ) async {
    final DemoApp d = await tall(t);
    expect(rowOf('demo-extra'), findsOneWidget);
    d.radio.setAvailable('demo-extra', available: false);
    await DemoApp.settle(t, 9);
    expect(rowOf('demo-extra'), findsOneWidget, reason: 'no flicker');
    await DemoApp.settle(t, 2);
    expect(rowOf('demo-extra'), findsNothing);
    d.radio.setAvailable('demo-extra', available: true);
    await DemoApp.settle(t, 1);
    expect(rowOf('demo-extra'), findsOneWidget);
    await DemoApp.shutDown(t);
  });

  testWidgets('legacy lights are never in "Nearby — not added"; they are in '
      '"Unsupported lights" at the bottom, and open the firmware update', (
    WidgetTester t,
  ) async {
    final DemoApp d = await tall(t);
    expect(
      d.radio.fixtures.any((SimFixture f) => f.id == 'demo-legacy'),
      isTrue,
    );
    final Finder nearbyTitle = find.text('Nearby — not added');
    final Finder unsupportedTitle = find.text('Unsupported lights');
    expect(nearbyTitle, findsOneWidget);
    expect(unsupportedTitle, findsOneWidget);
    expect(
      find.text('These lights run older firmware this app no longer supports.'),
      findsOneWidget,
    );
    expect(find.bySemanticsLabel('Unsupported lights'), findsOneWidget);
    // The legacy row sits under its own title, below the nearby list.
    final double legacyY = t.getTopLeft(rowOf('demo-legacy')).dy;
    expect(legacyY, greaterThan(t.getTopLeft(unsupportedTitle).dy));
    expect(
      t.getTopLeft(unsupportedTitle).dy,
      greaterThan(t.getTopLeft(rowOf('demo-extra')).dy),
    );
    final ProviderContainer c = ProviderScope.containerOf(
      t.element(find.byType(HomeScreen)),
      listen: false,
    );
    expect(
      c.read(nearbyProvider).where((NearbyLight n) => n.isLegacy).length,
      1,
    );
    // Only the supported one counts as nearby.
    expect(find.textContaining('· 1 nearby'), findsOneWidget);

    // With no other light nearby: only the unsupported section.
    d.radio.setAvailable('demo-extra', available: false);
    await DemoApp.settle(t, 12);
    expect(nearbyTitle, findsNothing);
    expect(unsupportedTitle, findsOneWidget);
    expect(rowOf('demo-legacy'), findsOneWidget);

    // A row opens the firmware update, as before.
    await t.ensureVisible(rowOf('demo-legacy'));
    await t.pump();
    await t.tap(rowOf('demo-legacy'));
    await DemoApp.settle(t, 2);
    expect(find.byType(FirmwareUpdateScreen), findsOneWidget);
    await DemoApp.shutDown(t);
  });
}
