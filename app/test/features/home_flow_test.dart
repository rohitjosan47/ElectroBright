import 'package:electrobright/app.dart';
import 'package:electrobright/app/app_session.dart';
import 'package:electrobright/bootstrap/service_registry.dart';
import 'package:electrobright/core/store/json_store.dart';
import 'package:electrobright/features/add_fixture/add_light_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Onboarding -> demo lights of every type -> add one -> it appears on Home
/// with its type.
void main() {
  Future<void> settle(WidgetTester t, [int seconds = 3]) async {
    for (int i = 0; i < seconds * 10; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
  }

  Widget app(JsonStore store) => ProviderScope(
    retry: (int retryCount, Object error) => null,
    overrides: [
      servicesProvider.overrideWithValue(AppServices()),
      storeProvider.overrideWithValue(store),
      demoStoreProvider.overrideWithValue(() async => JsonStore.memory()),
      legacyPrefsProvider.overrideWithValue(() async => null),
    ],
    child: const ElectroBrightApp(),
  );

  testWidgets('first launch offers real or demo lights', (
    WidgetTester t,
  ) async {
    await t.pumpWidget(app(JsonStore.memory()));
    await t.pump();
    expect(find.text('Use my lights'), findsOneWidget);
    expect(find.text('Try demo lights'), findsOneWidget);
  });

  testWidgets('demo lights of every type are found and one is added', (
    WidgetTester t,
  ) async {
    t.view.physicalSize = const Size(1179, 5200);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    final JsonStore store = JsonStore.memory();
    await t.pumpWidget(app(store));
    await t.pump();
    await t.tap(find.text('Try demo lights'));
    await settle(t);

    // Home, with every fixture type nearby (types from the BLE names).
    expect(find.text('Lights'), findsOneWidget);
    expect(find.text('Nearby — not added'), findsOneWidget);
    for (final String type in <String>[
      'RGBW · Colour + white',
      'RGB · Colour',
      'RGB + CCT · Colour + tunable white',
      'Tunable white · Tunable white (warm to cool)',
      'White · Single white',
    ]) {
      expect(find.text(type), findsOneWidget, reason: type);
    }
    expect(find.text('Update needed'), findsOneWidget); // the legacy light

    // Add the tunable-white light.
    await t.scrollUntilVisible(
      find.text('Tunable white · Tunable white (warm to cool)'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await t.tap(find.text('Tunable white · Tunable white (warm to cool)'));
    await settle(t);
    expect(find.byType(AddLightScreen), findsOneWidget);
    expect(
      find.text('Found a Tunable white (warm to cool) light · firmware 3.5.0'),
      findsOneWidget,
    );
    await t.enterText(find.byType(TextField), 'Kitchen');
    await t.tap(find.text('Save'));
    await settle(t);

    // Home: the new light with its type and state.
    expect(find.byType(AddLightScreen), findsNothing);
    expect(find.text('Kitchen'), findsOneWidget);
    expect(find.text('Tunable white'), findsWidgets); // type badge
    expect(find.textContaining('On · 100 %'), findsOneWidget);
    expect(find.text('Connected'), findsOneWidget);
    // Saved (in demo mode's own store) with the firmware's identity.
    final JsonStore demoStore = ProviderScope.containerOf(
      t.element(find.text('Kitchen')),
    ).read(appSessionProvider)!.store;
    expect(store.read('fixtures'), isNull); // real lights untouched
    final List<Object?> saved = demoStore.read('fixtures')! as List<Object?>;
    final Map<String, Object?> f = saved.single! as Map<String, Object?>;
    expect(f['name'], 'Kitchen');
    expect(f['layout'], 'CCT');
    expect(
      ((f['identity']! as Map<String, Object?>)['capabilities']!
          as Map<String, Object?>)['layout'],
      'CCT',
    );
    // Shut the app down (saves, then stops the simulated radio).
    await t.pumpWidget(const SizedBox());
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await settle(t, 1);
  });
}
