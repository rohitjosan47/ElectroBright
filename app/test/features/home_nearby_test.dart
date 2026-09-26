import 'package:electrobright/app/providers.dart';
import 'package:electrobright/features/home/home_screen.dart';
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
}
