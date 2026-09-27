// End-to-end on a simulator or device with the demo lights: onboarding,
// adding one light of every type through the real add flow, and each
// type's controls checked against its firmware twin, then the colour and
// white groups.
//
//   flutter test integration_test -d <simulator id>
import 'package:electrobright/app.dart';
import 'package:electrobright/app/app_session.dart';
import 'package:electrobright/bootstrap/service_registry.dart';
import 'package:electrobright/core/protocol/eb/eb_scene.dart';
import 'package:electrobright/core/store/json_store.dart';
import 'package:electrobright/design/components/glass_controls.dart';
import 'package:electrobright/design/controls/glass_slider.dart';
import 'package:electrobright/design/controls/hue_wheel.dart';
import 'package:electrobright/features/add_fixture/add_light_screen.dart';
import 'package:electrobright/features/control/control_screen.dart';
import 'package:electrobright/features/firmware_update/firmware_update_screen.dart';
import 'package:electrobright/features/groups/group_screen.dart';
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

  /// Drags the colour temperature to its warm or cool end (the LEDs' own).
  Future<void> slideTemperature(WidgetTester t, {required bool warm}) async {
    final Finder slider = find.byWidgetPredicate(
      (Widget w) => w is GlassSlider && w.semanticLabel == 'Colour temperature',
    );
    await t.ensureVisible(slider);
    await wait(t, 300);
    await t.drag(slider, Offset(warm ? -2000 : 2000, 0));
  }

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
      await waitFor(
        t,
        find.textContaining('firmware ${EbDeviceModel.firmwareVersion}'),
      );
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
    await slideTemperature(t, warm: true);
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
    await slideTemperature(t, warm: false);
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
    await slideTemperature(t, warm: true);
    await wait(t);
    final EbScene bedroom = twin('demo-rgbcct').scene;
    expect(bedroom.color.values, <int>[0, 0, 0, 0, 255]);
    await back();

    // The colour group: brightness, colour and a preset.
    Finder groupTab(String name) => find.descendant(
      of: find.byWidgetPredicate(
        (Widget w) => w.runtimeType.toString() == 'GlassSegmented<_GroupTab>',
      ),
      matching: find.text(name),
    );
    Future<void> openGroupCard(String kind) async {
      final Finder card = find.byKey(ValueKey<String>('group-card-$kind'));
      await t.scrollUntilVisible(
        card,
        -300,
        scrollable: find.byType(Scrollable).first,
      );
      await t.tap(card);
      await waitFor(t, find.byType(GroupScreen));
    }

    Finder groupList() => find
        .descendant(
          of: find.byType(GroupScreen),
          matching: find.byType(Scrollable),
        )
        .first;

    /// Scrolls the group screen back to its tabs and opens [name].
    Future<void> showTab(String name) async {
      await t.scrollUntilVisible(groupTab(name), -200, scrollable: groupList());
      await t.tap(groupTab(name));
      await wait(t, 800);
    }

    /// Back to Home from the top of the group screen.
    Future<void> leaveGroup() async {
      await t.scrollUntilVisible(
        find.descendant(
          of: find.byType(GroupScreen),
          matching: find.byIcon(Icons.chevron_left_rounded),
        ),
        -300,
        scrollable: groupList(),
      );
      await back();
    }

    Finder onGroup(String text) => find.descendant(
      of: find.byType(GroupScreen),
      matching: find.text(text),
    );

    await openGroupCard('colour');
    expect(onGroup('Colour lights'), findsOneWidget);
    await waitFor(t, onGroup('3 of 3 connected'), seconds: 20);
    const List<String> colourLights = <String>[
      'demo-rgb',
      'demo-rgbcct',
      'demo-rgbw',
    ];
    // Brightness: one drag sets every light.
    await t.drag(
      find.byKey(const ValueKey<String>('brightness')),
      const Offset(-80, 0),
    );
    await wait(t);
    final int level = twin(colourLights.first).scene.brightness;
    expect(level, lessThan(255));
    for (final String id in colourLights) {
      expect(twin(id).scene.brightness, level, reason: id);
    }
    // Colour: a hue on the wheel's ring reaches every light alike, white
    // LEDs off.
    Future<void> ring(double side) async {
      await t.ensureVisible(find.byType(HueWheel));
      await wait(t, 300);
      // The wheel is a square as tall as the widget, centred in it.
      final Rect wheel = t.getRect(find.byType(HueWheel));
      await t.tapAt(
        wheel.center + Offset(side * (wheel.shortestSide / 2 - 14), 0),
      );
      await wait(t);
    }

    // The lights start white: full saturation first (the square's top
    // right), then a hue on the ring.
    final Rect square = t.getRect(find.byType(HueWheel));
    await t.tapAt(
      square.center + Offset(square.shortestSide, -square.shortestSide) * 0.2,
    );
    await wait(t);
    await ring(1);
    final List<int> rgb = twin('demo-rgb').scene.color.values;
    expect(
      rgb.reduce((int a, int b) => a > b ? a : b) -
          rgb.reduce((int a, int b) => a < b ? a : b),
      greaterThan(100),
    );
    expect(twin('demo-rgbw').scene.color.values, <int>[...rgb, 0]);
    expect(twin('demo-rgbcct').scene.color.values, <int>[...rgb, 0, 0]);
    // Saved as a preset on the phone.
    final Finder slot = find.byKey(const ValueKey<String>('group-preset-0'));
    await t.tap(groupTab('Presets'));
    await wait(t, 800);
    await t.ensureVisible(slot);
    await wait(t, 300);
    await t.tap(slot);
    await wait(t, 800);
    await t.enterText(find.byType(TextField), 'Evening');
    await t.tap(find.text('Save'));
    await wait(t);
    expect(onGroup('Evening'), findsOneWidget);
    // Another colour; applying the preset brings the first one back.
    await showTab('Colour');
    await ring(-1);
    expect(twin('demo-rgb').scene.color.values, isNot(rgb));
    await showTab('Presets');
    await t.ensureVisible(slot);
    await wait(t, 300);
    await t.tap(slot);
    await wait(t);
    expect(twin('demo-rgb').scene.color.values, rgb);
    expect(onGroup('Current look: Evening'), findsOneWidget);
    await leaveGroup();

    // The white group: a temperature on the tunable white only.
    await openGroupCard('white');
    expect(onGroup('White lights'), findsOneWidget);
    await waitFor(t, onGroup('2 of 2 connected'), seconds: 20);
    final EbScene kitchenBefore = twin('demo-cct').scene;
    final EbScene hallwayBefore = twin('demo-w').scene;
    await slideTemperature(t, warm: false);
    await wait(t);
    expect(twin('demo-cct').scene.color, isNot(kitchenBefore.color));
    expect(twin('demo-w').scene.color, hallwayBefore.color);
    await leaveGroup();
    expect(find.byType(GroupScreen), findsNothing);
    // Back on Home, at its card.
    expect(find.byKey(const ValueKey<String>('groups-card')), findsOneWidget);

    // The light with the original firmware leads to the update screen.
    await scrollTo(t, find.text('Update needed'));
    // Clear of the Add light button.
    await t.ensureVisible(find.text('Update needed'));
    await wait(t, 300);
    await t.tap(find.text('Update needed'));
    await waitFor(t, find.byType(FirmwareUpdateScreen));
  });
}
