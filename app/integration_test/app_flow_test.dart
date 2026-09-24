// End-to-end on a simulator or device with the demo lights: onboarding,
// adding one light of every type through the real add flow, and each
// type's controls checked against its firmware twin.
//
//   flutter test integration_test -d <simulator id>
import 'package:electrobright/app.dart';
import 'package:electrobright/app/app_session.dart';
import 'package:electrobright/bootstrap/service_registry.dart';
import 'package:electrobright/core/protocol/eb/eb_scene.dart';
import 'package:electrobright/core/store/json_store.dart';
import 'package:electrobright/design/components/glass_controls.dart';
import 'package:electrobright/features/add_fixture/add_light_screen.dart';
import 'package:electrobright/features/control/control_screen.dart';
import 'package:electrobright/features/firmware_update/firmware_update_screen.dart';
import 'package:electrobright/sim/eb_device_model.dart';
import 'package:electrobright/sim/sim_central.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  /// Real time passes; frames keep coming.
  Future<void> wait(WidgetTester t, [int ms = 1500]) async {
    final DateTime until = DateTime.now().add(Duration(milliseconds: ms));
    while (DateTime.now().isBefore(until)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await t.pump();
    }
  }

  /// Waits (up to [seconds]) until [f] finds something.
  Future<void> waitFor(WidgetTester t, Finder f, {int seconds = 10}) async {
    for (int i = 0; i < seconds * 10; i++) {
      if (f.evaluate().isNotEmpty) return;
      await wait(t, 100);
    }
    expect(f, findsWidgets);
  }

  Future<void> scrollTo(WidgetTester t, Finder f) =>
      t.scrollUntilVisible(f, 200, scrollable: find.byType(Scrollable).first);

  Finder tab(String name) => find.descendant(
    of: find.byType(GlassSegmented<ControlTab>),
    matching: find.text(name),
  );

  testWidgets('demo lights of every type, end to end', (WidgetTester t) async {
    final AppServices services = AppServices();
    await t.pumpWidget(
      ProviderScope(
        retry: (int retryCount, Object error) => null,
        overrides: [
          servicesProvider.overrideWithValue(services),
          storeProvider.overrideWithValue(JsonStore.memory()),
          demoStoreProvider.overrideWithValue(() async => JsonStore.memory()),
          legacyPrefsProvider.overrideWithValue(() async => null),
        ],
        child: const ElectroBrightApp(),
      ),
    );
    await wait(t, 500);
    await t.tap(find.text('Try demo lights'));
    await waitFor(t, find.text('Nearby — not added'));

    EbDeviceModel twin(String id) => services.demoLights!.fixtures
        .firstWhere((SimFixture f) => f.id == id)
        .model;

    // Add one light of every type through the add flow.
    const List<(String, String, String)> lights = <(String, String, String)>[
      ('Kitchen', 'Tunable white · Tunable white (warm to cool)', 'demo-cct'),
      ('Hallway', 'White · Single white', 'demo-w'),
      ('Desk strip', 'RGB · Colour', 'demo-rgb'),
      ('Bedroom', 'RGB + CCT · Colour + tunable white', 'demo-rgbcct'),
      ('Living room', 'RGBW · Colour + white', 'demo-rgbw'),
    ];
    for (final (String name, String type, String _) in lights) {
      await scrollTo(t, find.text(type));
      await t.tap(find.text(type));
      await waitFor(t, find.textContaining('firmware 3.5.0'));
      expect(find.byType(AddLightScreen), findsOneWidget);
      await t.enterText(find.byType(TextField), name);
      // "Done" on the keyboard saves.
      await t.testTextInput.receiveAction(TextInputAction.done);
      for (
        int i = 0;
        i < 100 && find.byType(AddLightScreen).evaluate().isNotEmpty;
        i++
      ) {
        await wait(t, 100);
      }
      await wait(t, 500);
      // Home lists it (lazily built: scroll to it).
      await scrollTo(t, find.text(name));
      await t.scrollUntilVisible(
        find.text('Nearby — not added'),
        -200,
        scrollable: find.byType(Scrollable).first,
      );
    }

    Future<void> openLight(String name) async {
      await scrollTo(t, find.text(name));
      await t.tap(find.text(name));
      await waitFor(t, find.byType(ControlScreen));
      await wait(t, 1500);
    }

    Future<void> back() async {
      await t.tap(find.byIcon(Icons.chevron_left_rounded).first);
      await wait(t, 800);
    }

    // Tunable white: 2700 K at full level is the warm LED alone.
    await openLight('Kitchen');
    await t.tap(find.text('Warm 2700 K'));
    await wait(t);
    expect(twin('demo-cct').scene.color.values, <int>[0, 255]);
    // Preset: save, change, load back.
    await t.tap(tab('Presets'));
    await wait(t, 800);
    await t.tap(find.byKey(const ValueKey<String>('preset-0')));
    await wait(t, 800);
    await t.enterText(find.byType(TextField).last, 'Evening');
    await t.tap(find.text('Save').last);
    await wait(t);
    expect(twin('demo-cct').presetSlots, contains(0));
    await t.tap(tab('White'));
    await wait(t, 800);
    await t.tap(find.text('Daylight 6500 K'));
    await wait(t);
    expect(twin('demo-cct').scene.color.values, <int>[255, 0]);
    await t.tap(tab('Presets'));
    await wait(t, 800);
    await t.tap(find.byKey(const ValueKey<String>('preset-0')));
    await wait(t);
    expect(twin('demo-cct').scene.color.values, <int>[0, 255]);
    // Sleep timer.
    await t.tap(find.byKey(const ValueKey<String>('timer-button')));
    await wait(t, 800);
    await t.tap(find.byKey(const ValueKey<String>('timer-start')));
    await wait(t);
    expect(twin('demo-cct').timerActive, isTrue);
    await back();

    // Single white: no Rainbow, the pill is its intensity.
    await openLight('Hallway');
    expect(find.byKey(const ValueKey<String>('mode-10')), findsNothing);
    expect(find.byKey(const ValueKey<String>('mode-13')), findsOneWidget);
    await back();

    // RGB + CCT: the white side lights only the white LEDs.
    await openLight('Bedroom');
    await t.tap(find.text('Warm 2700 K'));
    await wait(t);
    final EbScene bedroom = twin('demo-rgbcct').scene;
    expect(bedroom.color.values, <int>[0, 0, 0, 0, 255]);
    await back();

    // The light with the original firmware leads to the update screen.
    await scrollTo(t, find.text('Update needed'));
    await t.tap(find.text('Update needed'));
    await waitFor(t, find.byType(FirmwareUpdateScreen));
  });
}
