import 'package:electrobright/sessions/fixture_session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/demo_app.dart';

/// Home's long-press Identify: a light that is not connected connects first
/// ("Connecting…"), then identifies once; it gives up after 10 s.
void main() {
  Future<DemoApp> start(WidgetTester t) async {
    t.view.physicalSize = const Size(393, 2600);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final DemoApp d = await DemoApp.start(t);
    await DemoApp.settle(t, 2);
    return d;
  }

  /// A saved light Home does not keep connected (it keeps three).
  String idle(DemoApp d) => DemoApp.lights.keys.firstWhere(
    (String n) => d.session(n).status.phase != LinkPhase.ready,
  );

  Future<void> identifyFromHome(WidgetTester t, String name) async {
    await t.ensureVisible(find.text(name));
    await t.pump();
    await t.longPress(find.text(name));
    await DemoApp.settle(t, 1);
    expect(find.text('Identify'), findsOneWidget, reason: 'the light menu');
    await t.tap(find.text('Identify'));
    await t.pump(const Duration(milliseconds: 100));
  }

  testWidgets('a light not connected connects, then identifies once; a '
      'second tap meanwhile does not stack', (WidgetTester t) async {
    final DemoApp d = await start(t);
    final String name = idle(d);
    final String device = DemoApp.lights[name]!.$1;
    // Out of reach for a moment, so the second tap lands while the first
    // is still connecting.
    d.radio.setAvailable(device, available: false);
    d.model(name).takeSounds();
    await identifyFromHome(t, name);
    expect(find.text('Connecting…'), findsWidgets);
    await identifyFromHome(t, name);
    d.radio.setAvailable(device, available: true);
    await DemoApp.settle(t, 4);
    expect(d.model(name).takeSounds(), <String>['Identify']);
    await DemoApp.shutDown(t);
  });

  testWidgets('a light out of reach: gives up after 10 s and says so', (
    WidgetTester t,
  ) async {
    final DemoApp d = await start(t);
    final String name = idle(d);
    d.radio.setAvailable(DemoApp.lights[name]!.$1, available: false);
    d.model(name).takeSounds();
    await identifyFromHome(t, name);
    await DemoApp.settle(t, 9);
    expect(find.text("$name didn't connect."), findsNothing);
    await DemoApp.settle(t, 2);
    expect(find.text("$name didn't connect."), findsOneWidget);
    expect(d.model(name).takeSounds(), isEmpty);
    await DemoApp.settle(t, 3); // the message's own time
    await DemoApp.shutDown(t);
  });
}
