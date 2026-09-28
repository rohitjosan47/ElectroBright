import 'package:electrobright/app.dart';
import 'package:electrobright/app/app_session.dart';
import 'package:electrobright/bootstrap/service_registry.dart';
import 'package:electrobright/core/model/channel_layout.dart';
import 'package:electrobright/core/model/fixture.dart';
import 'package:electrobright/core/store/json_store.dart';
import 'package:electrobright/design/gallery/gallery.dart';
import 'package:electrobright/features/add_fixture/add_light_screen.dart';
import 'package:electrobright/features/home/home_screen.dart';
import 'package:electrobright/sim/eb_device_model.dart';
import 'package:flutter/foundation.dart';
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

    // Home, empty: a welcome pointing to "Add light", which counts the
    // lights nearby (the legacy one never counts). Home lists none of them.
    expect(find.text('Lights'), findsOneWidget);
    expect(find.text('Add your first light'), findsOneWidget);
    expect(
      find.text('Switch your light on, then tap Add light below.'),
      findsOneWidget,
    );
    expect(find.text('0 of 0 connected'), findsOneWidget);
    expect(find.byType(NearbyRow), findsNothing);
    final SemanticsHandle semantics = t.ensureSemantics();
    expect(
      find.bySemanticsLabel(RegExp(r'^Add light, 5 lights nearby$')),
      findsOneWidget,
    );
    semantics.dispose();

    // The add screen, with every fixture type nearby (types from the BLE
    // names).
    await t.tap(find.text('Add light'));
    await settle(t, 2);
    expect(find.byType(AddLightScreen), findsOneWidget);
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
    await t.tap(find.text('Tunable white · Tunable white (warm to cool)'));
    await settle(t);
    expect(find.byType(AddLightScreen), findsOneWidget);
    expect(
      find.text(
        'Found a Tunable white (warm to cool) light · '
        'firmware ${EbDeviceModel.firmwareVersion}',
      ),
      findsOneWidget,
    );
    await t.enterText(find.byType(TextField), 'Kitchen');
    await t.tap(find.text('Save'));
    await settle(t);

    // Home: the new light with its type and state; no more welcome.
    expect(find.byType(AddLightScreen), findsNothing);
    expect(find.text('Kitchen'), findsOneWidget);
    expect(find.text('Add your first light'), findsNothing);
    expect(find.text('1 of 1 connected'), findsOneWidget);
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

  testWidgets('a new light is named after its type, numbered to be unique', (
    WidgetTester t,
  ) async {
    t.view.physicalSize = const Size(1179, 5200);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    await t.pumpWidget(app(JsonStore.memory()));
    await t.pump();
    await t.tap(find.text('Try demo lights'));
    await settle(t);
    final AppSession session = ProviderScope.containerOf(
      t.element(find.text('Lights')),
    ).read(appSessionProvider)!;
    // An RGBW light already saved under the type's name.
    session.registry.add(
      Fixture(
        id: 'fx-first',
        deviceId: 'elsewhere',
        name: 'RGBW light',
        layout: ChannelLayout.rgbw,
        driver: DriverKind.electroBright,
        addedAt: DateTime(2026),
      ),
    );
    await settle(t, 1);

    await t.tap(find.text('Add light'));
    await settle(t, 2);
    await t.tap(find.text('RGBW · Colour + white'));
    await settle(t);
    expect(find.byType(AddLightScreen), findsOneWidget);
    // Identify is there before saving.
    expect(find.byIcon(Icons.flare_rounded), findsOneWidget);
    expect(
      t.widget<TextField>(find.byType(TextField)).controller!.text,
      'RGBW light 2',
    );
    await t.tap(find.text('Save'));
    await settle(t);
    expect(session.registry.fixtures.map((Fixture f) => f.name), <String>[
      'RGBW light',
      'RGBW light 2',
    ]);
    await t.pumpWidget(const SizedBox());
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await settle(t, 1);
  });

  group('settings sheet', () {
    Future<void> openSheet(WidgetTester t) async {
      await t.pumpWidget(app(JsonStore.memory()));
      await t.pump();
      await t.tap(find.text('Try demo lights'));
      await settle(t);
      await t.tap(find.bySemanticsLabel('Settings'));
      await settle(t, 1);
      expect(find.byType(BottomSheet), findsOneWidget);
    }

    tearDown(() => debugShowDeveloperTools = kDebugMode);

    testWidgets('profile and release builds: no developer tools', (
      WidgetTester t,
    ) async {
      debugShowDeveloperTools = false;
      await openSheet(t);
      expect(find.text('Use my real lights'), findsOneWidget);
      expect(find.text('Diagnostics'), findsNothing);
      expect(find.text('Design gallery'), findsNothing);
    });

    testWidgets('debug builds: the gallery and the lab open from it', (
      WidgetTester t,
    ) async {
      debugShowDeveloperTools = true;
      await openSheet(t);
      expect(find.byKey(const ValueKey<String>('settings-lab')), findsOne);
      await t.tap(find.byKey(const ValueKey<String>('settings-gallery')));
      await settle(t, 1);
      expect(find.byType(ComponentGallery), findsOneWidget);
    });
  });
}
