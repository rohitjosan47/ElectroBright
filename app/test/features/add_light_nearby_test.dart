import 'package:electrobright/app/providers.dart';
import 'package:electrobright/features/add_fixture/add_light_screen.dart';
import 'package:electrobright/features/firmware_update/firmware_update_screen.dart';
import 'package:electrobright/sim/sim_central.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/demo_app.dart';

/// The add screen lists the nearby lights ("Not mine" hides one, "Show
/// hidden lights" brings them back), then the lights on unsupported
/// firmware at the bottom.
void main() {
  /// Demo lights plus [extra] unsaved ones, on the add screen.
  Future<DemoApp> onAddScreen(WidgetTester t, {int extra = 1}) async {
    t.view.physicalSize = const Size(393, 1400);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final DemoApp d = await DemoApp.start(t);
    for (int i = 1; i <= extra; i++) {
      d.radio.fixtures.add(SimFixture.electroBright(id: 'demo-extra-$i'));
    }
    await DemoApp.settle(t, 1);
    await t.tap(find.text('Add light'));
    await DemoApp.settle(t, 2);
    expect(find.byType(AddLightScreen), findsOneWidget);
    return d;
  }

  Finder rowOf(String deviceId) => find.byWidgetPredicate(
    (Widget w) => w is NearbyRow && w.light.seen.id == deviceId,
  );

  Finder notMine(String deviceId) =>
      find.byKey(ValueKey<String>('not-mine-$deviceId'));

  const ValueKey<String> showHidden = ValueKey<String>('show-hidden-lights');

  testWidgets('legacy lights are in "Unsupported lights" at the bottom, '
      'without "Not mine", and open the firmware update', (
    WidgetTester t,
  ) async {
    await onAddScreen(t);
    final Finder unsupportedTitle = find.text('Unsupported lights');
    expect(unsupportedTitle, findsOneWidget);
    expect(
      find.text('These lights run older firmware this app no longer supports.'),
      findsOneWidget,
    );
    final SemanticsHandle semantics = t.ensureSemantics();
    expect(find.bySemanticsLabel('Unsupported lights'), findsOneWidget);
    semantics.dispose();
    // The legacy row sits under its own title, below the nearby list.
    expect(
      t.getTopLeft(unsupportedTitle).dy,
      greaterThan(t.getTopLeft(rowOf('demo-extra-1')).dy),
    );
    expect(
      t.getTopLeft(rowOf('demo-legacy')).dy,
      greaterThan(t.getTopLeft(unsupportedTitle).dy),
    );
    expect(find.text('Update needed'), findsOneWidget);
    expect(notMine('demo-extra-1'), findsOneWidget);
    expect(notMine('demo-legacy'), findsNothing);

    await t.tap(rowOf('demo-legacy'));
    await DemoApp.settle(t, 2);
    expect(find.byType(FirmwareUpdateScreen), findsOneWidget);
    await DemoApp.shutDown(t);
  });

  testWidgets('only a legacy light nearby: still looking, and the '
      'unsupported section', (WidgetTester t) async {
    await onAddScreen(t, extra: 0);
    expect(find.text('Looking for lights…'), findsOneWidget);
    expect(find.text('Unsupported lights'), findsOneWidget);
    expect(rowOf('demo-legacy'), findsOneWidget);
    expect(find.byKey(showHidden), findsNothing);
    await DemoApp.shutDown(t);
  });

  testWidgets('"Not mine" hides a light (kept by device id); "Show hidden '
      'lights" brings it back', (WidgetTester t) async {
    final DemoApp d = await onAddScreen(t, extra: 2);
    expect(rowOf('demo-extra-1'), findsOneWidget);
    expect(rowOf('demo-extra-2'), findsOneWidget);
    expect(find.byKey(showHidden), findsNothing);

    await t.tap(notMine('demo-extra-1'));
    await t.pump();
    expect(rowOf('demo-extra-1'), findsNothing);
    expect(rowOf('demo-extra-2'), findsOneWidget);
    expect(find.byKey(showHidden), findsOneWidget);
    expect(find.text('Show hidden lights'), findsOneWidget);
    // Last on the screen.
    expect(
      t.getTopLeft(find.byKey(showHidden)).dy,
      greaterThan(t.getTopLeft(rowOf('demo-legacy')).dy),
    );
    // Kept in the session's store, by device id.
    expect(d.app.store.read('hiddenLights'), <String>['demo-extra-1']);
    // Still hidden while it keeps advertising, and when read again.
    await DemoApp.settle(t, 3);
    expect(rowOf('demo-extra-1'), findsNothing);
    final ProviderContainer c = ProviderScope.containerOf(
      t.element(find.byType(AddLightScreen)),
      listen: false,
    );
    c.invalidate(hiddenLightsProvider);
    expect(c.read(hiddenLightsProvider), <String>{'demo-extra-1'});
    await t.pump();
    expect(rowOf('demo-extra-1'), findsNothing);

    // Hiding the other one too: still looking, the row to bring them back.
    await t.tap(notMine('demo-extra-2'));
    await t.pump();
    expect(find.text('Looking for lights…'), findsOneWidget);
    expect(d.app.store.read('hiddenLights'), <String>[
      'demo-extra-1',
      'demo-extra-2',
    ]);

    await t.tap(find.byKey(showHidden));
    await t.pump();
    expect(rowOf('demo-extra-1'), findsOneWidget);
    expect(rowOf('demo-extra-2'), findsOneWidget);
    expect(find.byKey(showHidden), findsNothing);
    expect(d.app.store.read('hiddenLights'), <String>[]);
    await DemoApp.shutDown(t);
  });

  testWidgets('a nearby light is added from the add screen', (
    WidgetTester t,
  ) async {
    final DemoApp d = await onAddScreen(t);
    await t.tap(rowOf('demo-extra-1'));
    await DemoApp.settle(t, 3);
    expect(find.textContaining('Found a'), findsOneWidget);
    await t.enterText(find.byType(TextField), 'Porch');
    await t.tap(find.text('Save'));
    await DemoApp.settle(t, 2);
    expect(find.byType(AddLightScreen), findsNothing);
    expect(
      d.app.registry.fixtures
          .where((f) => f.deviceId == 'demo-extra-1')
          .single
          .name,
      'Porch',
    );
    await DemoApp.shutDown(t);
  });
}
