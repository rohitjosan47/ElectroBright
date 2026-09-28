import 'dart:async';

import 'package:electrobright/features/diagnostics/ble_lab.dart';
import 'package:electrobright/features/home/home_screen.dart';
import 'package:electrobright/sessions/connection_manager.dart';
import 'package:electrobright/sessions/discovery.dart';
import 'package:electrobright/sim/sim_central.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/demo_app.dart';

/// The BLE Lab registers the lights it connects (they are not saved): each
/// is gone when the lab connects another one or closes, with its link, want
/// and scan lease.
void main() {
  testWidgets('leaving the lab holds nothing it took', (WidgetTester t) async {
    t.view.physicalSize = const Size(393, 2400);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final DemoApp d = await DemoApp.start(t);
    for (final String id in <String>['demo-lab-1', 'demo-lab-2']) {
      d.radio.fixtures.add(SimFixture.electroBright(id: id));
    }
    await DemoApp.settle(t, 2);
    final ConnectionManager cm = d.app.ble.connections;
    final Discovery discovery = d.app.ble.discovery;
    SimFixture sim(String id) =>
        d.radio.fixtures.firstWhere((SimFixture f) => f.id == id);

    unawaited(
      Navigator.of(t.element(find.byType(HomeScreen)))
          .push(MaterialPageRoute<void>(builder: (_) => const BleLabScreen())),
    );
    await DemoApp.settle(t, 1);
    await t.tap(find.text('Demo lights'));
    await DemoApp.settle(t, 2);

    Future<void> connect(String id) async {
      final Finder tile = find.textContaining(id);
      await t.ensureVisible(tile);
      await t.pump();
      await t.tap(tile);
      await DemoApp.settle(t, 3);
      expect(cm.session('lab-$id')!.status.isReady, isTrue, reason: id);
    }

    await connect('demo-lab-1');
    // Another light: the first one is let go at once.
    await connect('demo-lab-2');
    expect(cm.session('lab-demo-lab-1'), isNull);
    await DemoApp.settle(t, 1);
    expect(sim('demo-lab-1').connected, isFalse);

    // Leave the lab.
    await t.pageBack();
    await DemoApp.settle(t, 2);
    expect(find.byType(BleLabScreen), findsNothing);
    expect(cm.session('lab-demo-lab-2'), isNull, reason: 'unregistered');
    expect(sim('demo-lab-2').connected, isFalse, reason: 'link closed');
    expect(cm.sessions.where((s) => s.fixture.id.startsWith('lab-')), isEmpty);
    expect(cm.manages('demo-lab-2'), isFalse, reason: 'forgettable again');
    // Home's own scan is all that remains (no lab lease).
    expect(discovery.strongestNeed, ScanNeed.badge);
    await DemoApp.shutDown(t);
  });
}
