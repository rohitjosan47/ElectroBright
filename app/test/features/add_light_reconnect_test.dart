import 'package:clock/clock.dart';
import 'package:electrobright/app.dart';
import 'package:electrobright/app/app_session.dart';
import 'package:electrobright/bootstrap/service_registry.dart';
import 'package:electrobright/core/store/json_store.dart';
import 'package:electrobright/core/util/scheduler.dart';
import 'package:electrobright/features/add_fixture/add_light_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Adding a light, going back without saving and picking the same light
/// again connects every time (demo mode).
void main() {
  Future<void> settle(WidgetTester t, [int seconds = 3]) async {
    for (int i = 0; i < seconds * 10; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('pick, back, pick the same light: found, three times; a light '
      'gone meanwhile fails within 20 s', (WidgetTester t) async {
    t.view.physicalSize = const Size(393, 2400);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final Stopwatch watch = clock.stopwatch()..start();
    await t.pumpWidget(
      ProviderScope(
        retry: (int retryCount, Object error) => null,
        overrides: [
          servicesProvider.overrideWithValue(
            AppServices(
              scheduler: SystemScheduler(elapsed: () => watch.elapsed),
            ),
          ),
          storeProvider.overrideWithValue(JsonStore.memory()),
          demoStoreProvider.overrideWithValue(() async => JsonStore.memory()),
          legacyPrefsProvider.overrideWithValue(() async => null),
        ],
        child: const ElectroBrightApp(),
      ),
    );
    await t.pump();
    await t.tap(find.text('Try demo lights'));
    await settle(t);
    const String row = 'Tunable white · Tunable white (warm to cool)';
    for (int round = 1; round <= 3; round++) {
      await t.scrollUntilVisible(
        find.text(row),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await t.tap(find.text(row));
      await settle(t);
      expect(find.byType(AddLightScreen), findsOneWidget);
      expect(
        find.textContaining('Found a Tunable white'),
        findsOneWidget,
        reason: 'round $round',
      );
      await t.tap(find.byIcon(Icons.close_rounded));
      await settle(t, 1);
      expect(find.byType(AddLightScreen), findsNothing);
    }
    // A light that switched off after it was listed: "Connecting…" ends in
    // the failure message within 20 s.
    await t.scrollUntilVisible(
      find.text(row),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    ProviderScope.containerOf(t.element(find.text(row)))
        .read(servicesProvider)
        .demoLights!
        .setAvailable('demo-cct', available: false);
    await t.tap(find.text(row));
    await settle(t, 1);
    expect(find.byType(AddLightScreen), findsOneWidget);
    expect(find.text('Connecting…'), findsWidgets);
    await settle(t, 19);
    expect(find.textContaining("Couldn't connect"), findsNothing);
    await settle(t, 2);
    expect(find.textContaining("Couldn't connect"), findsOneWidget);
    await t.tap(find.byIcon(Icons.close_rounded));
    await settle(t, 1);
    await t.pumpWidget(const SizedBox());
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await settle(t, 1);
  });
}
