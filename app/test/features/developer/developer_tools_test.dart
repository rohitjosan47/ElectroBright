import 'package:electrobright/app/app_session.dart';
import 'package:electrobright/core/model/channel_layout.dart';
import 'package:electrobright/core/model/fixture.dart';
import 'package:electrobright/core/model/light_capabilities.dart';
import 'package:electrobright/features/add_fixture/add_light_screen.dart';
import 'package:electrobright/features/control/control_screen.dart';
import 'package:electrobright/features/control/presets/preset_meta.dart';
import 'package:electrobright/features/developer/developer_screen.dart';
import 'package:electrobright/features/developer/light_developer_screen.dart';
import 'package:electrobright/features/fixture_settings/light_settings_screen.dart';
import 'package:electrobright/sim/sim_central.dart';
import 'package:electrobright/sim/eb_device_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/demo_app.dart';

/// The firmware version the app bundles (and the demo lights run).
const String _current = EbDeviceModel.firmwareVersion;

/// Developer tools: the switch in Settings, the Developer list, a light's
/// developer page (probe test, type change, firmware, diagnostics) and the
/// setup flow of a light without a type — against the demo twins.
void main() {
  Future<void> settle(WidgetTester t, [int seconds = 2]) =>
      DemoApp.settle(t, seconds);

  Future<DemoApp> start(WidgetTester t) async {
    t.view.physicalSize = const Size(1179, 7000);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    return DemoApp.start(t);
  }

  /// [settle], giving real async a turn each frame: a link dropped by the
  /// light's restart is torn down (demo-mode teardown needs real time).
  Future<void> settleRestart(WidgetTester t, [int seconds = 8]) async {
    for (int i = 0; i < seconds * 10; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 2)),
      );
      await t.pump(const Duration(milliseconds: 100));
    }
  }

  Finder key(String k) => find.byKey(ValueKey<String>(k));

  ProviderContainer container(WidgetTester t) =>
      ProviderScope.containerOf(t.element(find.byType(MaterialApp)));

  Future<void> openSheet(WidgetTester t) async {
    await t.tap(find.bySemanticsLabel('Settings'));
    await settle(t, 1);
    expect(find.byType(BottomSheet), findsOneWidget);
  }

  Future<void> closeSheet(WidgetTester t) async {
    Navigator.of(t.element(find.byType(BottomSheet))).pop();
    await settle(t, 1);
  }

  Future<void> pop(WidgetTester t, Type screen) async {
    Navigator.of(t.element(find.byType(screen))).pop();
    await settle(t, 1);
  }

  Future<void> toggleTools(WidgetTester t) async {
    await openSheet(t);
    await t.tap(key('settings-developer-tools'));
    await settle(t, 1);
  }

  /// Settings → Developer → [name]'s developer page.
  Future<void> openDeveloper(WidgetTester t, DemoApp d, String name) async {
    await toggleTools(t);
    await t.tap(key('settings-developer'));
    await settle(t, 1);
    expect(find.byType(DeveloperScreen), findsOneWidget);
    await t.tap(key('dev-light-${d.id(name)}'));
    await settle(t, 2);
    expect(find.byType(LightDeveloperScreen), findsOneWidget);
  }

  Map<String, Object> render(DemoApp d, String name) =>
      d.model(name).state()['render']! as Map<String, Object>;

  /// Answers the probe test: lit for the outputs in [lit] (red, green,
  /// blue, white, warm).
  Future<void> answer(WidgetTester t, List<bool> lit) async {
    for (final bool on in lit) {
      await settle(t, 1);
      await t.tap(key(on ? 'probe-yes' : 'probe-no'));
    }
    await settle(t, 1);
  }

  testWidgets('the switch hides and shows every trace of the tools', (
    WidgetTester t,
  ) async {
    final DemoApp d = await start(t);
    await openSheet(t);
    expect(find.text('ADVANCED'), findsOneWidget);
    expect(
      find.text('Tools for setting up and maintaining your lights.'),
      findsOneWidget,
    );
    expect(key('settings-developer'), findsNothing);
    await t.tap(key('settings-developer-tools'));
    await settle(t, 1);
    expect(key('settings-developer'), findsOneWidget);
    final Object? settings = container(t).read(storeProvider).read('settings');
    expect((settings! as Map<String, Object?>)['developerTools'], isTrue);

    // Settings → Developer lists every light with type, firmware and state.
    await t.tap(key('settings-developer'));
    await settle(t, 1);
    for (final String name in DemoApp.lights.keys) {
      expect(key('dev-light-${d.id(name)}'), findsOneWidget, reason: name);
    }
    expect(find.textContaining('Firmware $_current'), findsWidgets);
    await pop(t, DeveloperScreen);

    // A light's settings has a Developer row.
    await d.open(t, 'Living room');
    await t.tap(key('settings-button'));
    await settle(t, 1);
    expect(key('light-settings-developer'), findsOneWidget);
    await t.tap(key('light-settings-developer'));
    await settle(t, 1);
    expect(find.byType(LightDeveloperScreen), findsOneWidget);
    await pop(t, LightDeveloperScreen);
    await pop(t, LightSettingsScreen);
    await pop(t, ControlScreen);

    // Off: gone from Settings and from the light's settings.
    await toggleTools(t);
    expect(key('settings-developer'), findsNothing);
    expect(find.text('Developer'), findsNothing);
    await closeSheet(t);
    await d.open(t, 'Living room');
    await t.tap(key('settings-button'));
    await settle(t, 1);
    expect(find.byType(LightSettingsScreen), findsOneWidget);
    expect(key('light-settings-developer'), findsNothing);
    expect(find.text('Developer'), findsNothing);
    await DemoApp.shutDown(t);
  });

  testWidgets('the probe test lights each output and suggests the type', (
    WidgetTester t,
  ) async {
    final DemoApp d = await start(t);
    await openDeveloper(t, d, 'Hallway');
    await t.tap(key('dev-find-type'));
    await settle(t, 1);
    expect(find.text('Output 1 of 5'), findsOneWidget);
    expect(find.text('Is it lighting up?'), findsOneWidget);
    expect(render(d, 'Hallway')['probe'], 1); // red
    // The light ends a PROBE by itself after 3 s; the app keeps it lit while
    // the question is open (a late look must not read as "No"), and Retry
    // lights it again.
    await settle(t, 4);
    expect(render(d, 'Hallway')['probe'], 1);
    await t.tap(key('probe-retry'));
    await settle(t, 1);
    expect(render(d, 'Hallway')['probe'], 1);
    await t.tap(key('probe-no'));
    await settle(t, 1);
    expect(find.text('Output 2 of 5'), findsOneWidget);
    expect(render(d, 'Hallway')['probe'], 2); // green
    await answer(t, <bool>[false, false, true, true]);
    expect(render(d, 'Hallway')['probe'], 0); // ended
    expect(find.text('Looks like Tunable white'), findsOneWidget);
    expect(find.text('Lit: White or cool white, Warm white'), findsOneWidget);

    // No type matches red + white.
    await t.tap(key('probe-again'));
    await answer(t, <bool>[true, false, false, true, false]);
    expect(key('probe-no-match'), findsOneWidget);
    expect(key('probe-use'), findsNothing);
    // Nothing lit.
    await t.tap(key('probe-again'));
    await answer(t, <bool>[false, false, false, false, false]);
    expect(
      find.text(
        'Nothing lit up. Check the power and the wiring, then run the '
        'test again.',
      ),
      findsOneWidget,
    );
    // Red, green, blue: RGB, preselected in the list.
    await t.tap(key('probe-again'));
    await answer(t, <bool>[true, true, true, false, false]);
    expect(find.text('Looks like RGB'), findsOneWidget);
    await t.tap(key('probe-use'));
    await settle(t, 1);
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.text('Suggested'), findsOneWidget);
    expect(
      t
          .widget<Semantics>(
            find
                .ancestor(
                  of: key('dev-type-RGB'),
                  matching: find.byType(Semantics),
                )
                .first,
          )
          .properties
          .selected,
      isTrue,
    );
    // Every type stays selectable.
    await t.tap(key('dev-type-RGBW'));
    await settle(t, 1);
    expect(
      t
          .widget<Semantics>(
            find
                .ancestor(
                  of: key('dev-type-RGBW'),
                  matching: find.byType(Semantics),
                )
                .first,
          )
          .properties
          .selected,
      isTrue,
    );
    // Nothing changed on the light.
    expect(d.model('Hallway').restarts, 0);
    await DemoApp.shutDown(t);
  });

  testWidgets('changing the type: restart, re-identified, new group, '
      'preset names cleared', (WidgetTester t) async {
    final DemoApp d = await start(t);
    final String id = d.id('Hallway');
    await openDeveloper(t, d, 'Hallway');
    container(t).read(presetMetaProvider(id).notifier).rename(0, 'Night');
    expect(d.app.groups.white.members, contains(id));
    expect(find.text('Current'), findsOneWidget);
    // The current type can't be "changed" to.
    await t.tap(key('dev-type-W'));
    await settle(t, 1);
    expect(t.widget<FilledButton>(key('dev-change-type')).onPressed, isNull);
    await t.tap(key('dev-type-RGB'));
    await settle(t, 1);
    await t.tap(key('dev-change-type'));
    await settle(t, 1);
    expect(find.text('Make it RGB?'), findsOneWidget);
    expect(
      find.text(
        'Hallway restarts as a RGB light. Its presets are cleared, and it '
        'moves to Colour lights.',
      ),
      findsOneWidget,
    );
    await t.tap(key('change-type-confirm'));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text('Restarting as RGB…'), findsOneWidget);
    await settleRestart(t);

    expect(d.model('Hallway').restarts, 1);
    expect(d.model('Hallway').fixture.layout, ChannelLayout.rgb);
    final Fixture f = d.app.registry.byId(id)!;
    expect(f.layout, ChannelLayout.rgb);
    expect(f.identity!.model, 'EB-C3-RGB-V1');
    expect(d.session('Hallway').status.isReady, isTrue);
    expect(find.text('Hallway is now a RGB light'), findsWidgets);
    expect(d.app.groups.white.members, isNot(contains(id)));
    expect(d.app.groups.colour.members, contains(id));
    expect(container(t).read(presetMetaProvider(id)).slots, isEmpty);
    expect(d.app.store.read('presetMeta'), isNot(contains(id)));
    // The page shows the new type.
    expect(find.text('Current'), findsOneWidget);
    expect(
      find.descendant(of: key('dev-type-RGB'), matching: find.text('Current')),
      findsOneWidget,
    );
    await DemoApp.shutDown(t);
  });

  testWidgets('SET_TYPE reached the light but its OK was lost to the drop: '
      'back as the new type, the change is done', (WidgetTester t) async {
    final DemoApp d = await start(t);
    final String id = d.id('Hallway');
    final String device = d.app.registry.byId(id)!.deviceId;
    await openDeveloper(t, d, 'Hallway');
    await t.tap(key('dev-type-RGB'));
    await settle(t, 1);
    await t.tap(key('dev-change-type'));
    await settle(t, 1);
    // The light takes SET_TYPE, but its OK never gets out; then the link
    // drops (and the light restarts as RGB).
    d.model('Hallway').failNextNotifies(1 << 20);
    await t.tap(key('change-type-confirm'));
    await settleRestart(t, 1);
    d.radio.setAvailable(device, available: false);
    await settleRestart(t, 1);
    expect(find.text('Restarting as RGB…'), findsOneWidget);
    d.radio.setAvailable(device, available: true);
    await settleRestart(t, 8);
    expect(find.text('Hallway is now a RGB light'), findsWidgets);
    expect(d.model('Hallway').fixture.layout, ChannelLayout.rgb);
    expect(d.app.registry.byId(id)!.layout, ChannelLayout.rgb);
    await DemoApp.shutDown(t);
  });

  testWidgets('the link drops before SET_TYPE is sent: once the light is '
      'back as its old type the page says so, never stuck', (
    WidgetTester t,
  ) async {
    final DemoApp d = await start(t);
    final String id = d.id('Hallway');
    final String device = d.app.registry.byId(id)!.deviceId;
    await openDeveloper(t, d, 'Hallway');
    await t.tap(key('dev-type-RGB'));
    await settle(t, 1);
    await t.tap(key('dev-change-type'));
    await settle(t, 1);
    // Gone while the dialog is open; back two seconds later.
    d.radio.setAvailable(device, available: false);
    await t.tap(key('change-type-confirm'));
    await settleRestart(t, 2);
    expect(find.text('Restarting as RGB…'), findsOneWidget);
    d.radio.setAvailable(device, available: true);
    await settleRestart(t, 6);
    expect(
      find.text(
        "The type wasn't changed. Check the light is connected and try again.",
      ),
      findsOneWidget,
    );
    expect(d.model('Hallway').restarts, 0);
    expect(d.app.registry.byId(id)!.layout, ChannelLayout.w);
    expect(d.session('Hallway').status.isReady, isTrue);
    await DemoApp.shutDown(t);
  });

  testWidgets('a light without a type: "Setup needed" on Home, only the '
      'setup flow, in no group until set up', (WidgetTester t) async {
    final DemoApp d = await start(t);
    d.radio.fixtures.add(SimFixture.setupNeeded(id: 'demo-setup'));
    const String id = 'f-demo-setup';
    d.app.registry.add(
      Fixture(
        id: id,
        deviceId: 'demo-setup',
        name: 'Porch',
        layout: ChannelLayout.rgbw,
        driver: DriverKind.electroBright,
        addedAt: DateTime(2027),
      ),
    );
    // Home connects it: the handshake finds no type and lets it go.
    await settleRestart(t, 4);
    // Developer tools are off.
    expect(d.app.registry.byId(id)!.setupNeeded, isTrue);
    final Finder tile = find.ancestor(
      of: find.text('Porch'),
      matching: find.byKey(const ValueKey<String>(id)),
    );
    expect(
      find.descendant(of: tile, matching: find.text('Setup needed')),
      findsWidgets,
    );
    expect(d.app.groups.colour.members, isNot(contains(id)));

    await t.tap(find.text('Porch'));
    await settleRestart(t, 3);
    expect(find.byType(LightDeveloperScreen), findsOneWidget);
    expect(find.text('Set up this light'), findsOneWidget);
    expect(find.text('FIRMWARE'), findsNothing);
    expect(find.text('DIAGNOSTICS'), findsNothing);
    await t.tap(key('dev-find-type'));
    await answer(t, <bool>[true, true, true, true, true]);
    expect(find.text('Looks like RGB + CCT'), findsOneWidget);
    await t.tap(key('probe-use'));
    await settle(t, 1);
    await t.tap(key('dev-change-type'));
    await settle(t, 1);
    await t.tap(key('change-type-confirm'));
    await settleRestart(t);

    final Fixture f = d.app.registry.byId(id)!;
    expect(f.layout, ChannelLayout.rgbcct);
    expect(f.setupNeeded, isFalse);
    expect(d.app.groups.colour.members, contains(id));
    // Nothing it was sent was refused.
    final SimFixture sim = d.radio.fixtures.last;
    final Map<String, Object> stats =
        sim.model.state()['stats']! as Map<String, Object>;
    expect(stats['err'], 0);
    Navigator.of(t.element(find.byType(LightDeveloperScreen))).pop();
    await settle(t, 1);
    expect(
      find.descendant(of: tile, matching: find.text('Setup needed')),
      findsNothing,
    );
    expect(
      find.descendant(of: tile, matching: find.text('RGB + CCT')),
      findsOneWidget,
    );
    await DemoApp.shutDown(t);
  });

  testWidgets('adding a light without a type saves it as Setup needed', (
    WidgetTester t,
  ) async {
    final DemoApp d = await start(t);
    d.radio.fixtures.add(SimFixture.setupNeeded(id: 'demo-setup'));
    await settle(t, 2);
    await t.tap(find.text('Add light'));
    await settle(t, 2);
    await t.tap(find.text('ElectroBright_C3_SETUP'));
    await settleRestart(t, 4);
    expect(find.byType(AddLightScreen), findsOneWidget);
    expect(find.text('Found a light that needs setting up'), findsOneWidget);
    await t.tap(find.text('Save'));
    await settle(t, 1);
    final Fixture f = d.app.registry.fixtures.firstWhere(
      (Fixture f) => f.deviceId == 'demo-setup',
    );
    expect(f.setupNeeded, isTrue);
    expect(f.name, 'New light');
    expect(find.text('Setup needed'), findsWidgets);
    await DemoApp.shutDown(t);
  });

  testWidgets('diagnostics: readable, refreshed and copied', (
    WidgetTester t,
  ) async {
    final DemoApp d = await start(t);
    String? copied;
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map<Object?, Object?>)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await openDeveloper(t, d, 'Living room');
    expect(key('dev-firmware'), findsOneWidget);
    // Installed, and next to it the version bundled with the app.
    expect(
      find.descendant(of: key('dev-firmware'), matching: find.text(_current)),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: key('dev-bundled-firmware'),
        matching: find.text(_current),
      ),
      findsOneWidget,
    );
    expect(key('diag-uptime'), findsOneWidget);
    expect(find.text('Powered on'), findsOneWidget);
    expect(find.text('Firmware slot'), findsOneWidget);
    expect(find.text('None'), findsOneWidget); // no rollback
    expect(find.text('Confirmed'), findsOneWidget); // pv=0
    expect(find.text('RENDERING'), findsOneWidget);
    expect(find.text('CONNECTION'), findsOneWidget);
    expect(find.text('Lines received'), findsOneWidget);
    int rx() =>
        (d.model('Living room').state()['stats']! as Map<String, Object>)['rx']!
            as int;
    final int before = rx();
    await t.ensureVisible(key('dev-diag-refresh'));
    await t.pump();
    await t.tap(key('dev-diag-refresh'));
    await settle(t, 1);
    expect(rx(), before + 1);
    await t.tap(key('dev-diag-copy'));
    await t.pump();
    expect(copied, startsWith('Living room · Firmware $_current\n'));
    expect(copied, contains('Last restart: Powered on'));
    expect(copied!.split('\n').last, startsWith('DIAG:rx='));
    expect(find.text('Copied'), findsOneWidget);
    await settle(t, 3);
    await DemoApp.shutDown(t);
  });

  testWidgets('firmware without TYPES: the type needs 3.7.0 or later', (
    WidgetTester t,
  ) async {
    final DemoApp d = await start(t);
    d.app.registry.add(
      Fixture(
        id: 'f-old',
        deviceId: 'not-around',
        name: 'Old lamp',
        layout: ChannelLayout.rgbw,
        driver: DriverKind.electroBright,
        addedAt: DateTime(2026),
        identity: FixtureIdentity(
          capabilities: LightCapabilities.assumed(ChannelLayout.rgbw),
          model: 'EB-C3-RGBW-V1',
          firmwareVersion: '3.6.2',
        ),
      ),
    );
    await toggleTools(t);
    await t.tap(key('settings-developer'));
    await settle(t, 1);
    expect(find.textContaining('Firmware 3.6.2'), findsOneWidget);
    await t.tap(key('dev-light-f-old'));
    await settle(t, 2);
    expect(
      find.text(
        'Changing the type needs firmware 3.7.0 or later. This light runs '
        '3.6.2.',
      ),
      findsOneWidget,
    );
    expect(key('dev-find-type'), findsNothing);
    expect(t.widget<FilledButton>(key('dev-change-type')).onPressed, isNull);
    await DemoApp.shutDown(t);
  });
}
