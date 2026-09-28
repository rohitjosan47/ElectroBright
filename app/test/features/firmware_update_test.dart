import 'package:electrobright/core/model/channel_layout.dart';
import 'package:electrobright/core/model/fixture.dart';
import 'package:electrobright/design/platform/platform_api.g.dart';
import 'package:electrobright/design/platform/platform_bridge.dart';
import 'package:electrobright/features/developer/developer_tools.dart';
import 'package:electrobright/features/developer/light_developer_screen.dart';
import 'package:electrobright/features/firmware_update/update_firmware_screen.dart';
import 'package:electrobright/features/fixture_settings/light_settings_screen.dart';
import 'package:electrobright/features/groups/group_screen.dart';
import 'package:electrobright/features/home/home_screen.dart';
import 'package:electrobright/l10n/app_localizations_en.dart';
import 'package:electrobright/sessions/connection_manager.dart';
import 'package:electrobright/sessions/firmware_update.dart';
import 'package:electrobright/sessions/fixture_session.dart';
import 'package:electrobright/sim/sim_central.dart';
import 'package:electrobright/sim/eb_device_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/demo_app.dart';

/// The firmware version the app bundles (and the demo lights run).
const String _current = EbDeviceModel.firmwareVersion;

/// Records the keep-awake calls (everything else has no host in tests).
final class _Host extends PlatformHostApi {
  final List<bool> awake = <bool>[];
  @override
  Future<void> setKeepAwake(bool on) async => awake.add(on);
}

Finder _key(String k) => find.byKey(ValueKey<String>(k));

/// [seconds] of app time in 100 ms frames, each with a moment of real time:
/// a link torn down by a restart finishes only in real async (the stream
/// cancels complete in the root zone).
Future<void> _settle(WidgetTester t, [int seconds = 2]) async {
  for (int i = 0; i < seconds * 10; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1)),
    );
    await t.pump(const Duration(milliseconds: 100));
  }
}

/// Wireless firmware updates in demo mode: the demo's RGB light ("Desk
/// strip") runs 3.7.0; the app bundles the current firmware.
void main() {
  late _Host host;

  Future<DemoApp> start(WidgetTester t) async {
    host = _Host();
    return DemoApp.start(
      t,
      platform: PlatformBridge(api: host),
      olderFirmware: true,
    );
  }

  /// Keeps [name] connected (as a screen would).
  Want connect(DemoApp d, String name) {
    final Want w = d.app.ble.connections.want(d.id(name), WantReason.screen);
    addTearDown(w.release);
    return w;
  }

  Future<void> push(WidgetTester t, Widget screen) async {
    final NavigatorState nav = Navigator.of(
      t.element(find.byType(HomeScreen, skipOffstage: false)),
    );
    // Not awaited: the route stays until popped.
    // ignore: unawaited_futures
    nav.push(MaterialPageRoute<void>(builder: (_) => screen));
    await _settle(t, 1);
  }

  void pop(WidgetTester t, Type screen) =>
      Navigator.of(t.element(find.byType(screen))).pop();

  Future<void> startUpdate(WidgetTester t) async {
    await t.tap(_key('update-start'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 600));
  }

  testWidgets('an older light gets a badge and a banner; the update runs to '
      'the end', (WidgetTester t) async {
    final DemoApp d = await start(t);
    connect(d, 'Desk strip');
    connect(d, 'Living room');
    await _settle(t);
    // Only Desk strip (3.7.0) has an update; Living room runs the current firmware.
    expect(find.text('1 light has an update'), findsOneWidget);
    expect(_key('tile-update-badge'), findsOneWidget);
    final Rect badge = t.getRect(_key('tile-update-badge'));
    final Rect tile = t.getRect(
      find.ancestor(
        of: find.text('Desk strip'),
        matching: find.byKey(ValueKey<String>(d.id('Desk strip'))),
      ),
    );
    expect(tile.contains(badge.center), isTrue);

    await t.tap(_key('home-updates-banner'));
    await _settle(t, 1);
    expect(find.byType(UpdateFirmwareScreen), findsOneWidget);
    expect(find.text('Update firmware'), findsOneWidget);
    expect(find.text('3.7.0 → $_current'), findsOneWidget);
    expect(
      find.text('Keep the app open and stay near the light.'),
      findsOneWidget,
    );
    expect(find.textContaining('Desk strip gets firmware $_current'), findsOne);
    expect(host.awake, isEmpty);

    await startUpdate(t);
    expect(find.text('Sending the firmware…'), findsOneWidget);
    expect(_key('update-cancel'), findsOneWidget);
    expect(host.awake, <bool>[true]);
    await _settle(t, 2);
    final String percent = t.widget<Text>(_key('update-percent')).data!;
    expect(percent, matches(RegExp(r'^\d+ %$')));
    expect(int.parse(percent.split(' ').first), greaterThan(0));
    expect(_key('update-time-left'), findsOneWidget);
    expect(
      t.widget<LinearProgressIndicator>(_key('update-progress')).value,
      greaterThan(0),
    );

    // Home: the light says "Updating…"; a tap shows the progress again. The
    // screen stays awake for the whole update, on any screen.
    pop(t, UpdateFirmwareScreen);
    await _settle(t, 1);
    expect(find.text('Updating…'), findsOneWidget);
    expect(find.text('1 light has an update'), findsNothing);
    expect(d.session('Desk strip').status.updating, isTrue);
    expect(host.awake, <bool>[true]);
    await t.tap(find.text('Desk strip'));
    await _settle(t, 1);
    expect(find.byType(UpdateFirmwareScreen), findsOneWidget);

    await _settle(t, 35);
    expect(find.text('Updated to $_current'), findsOneWidget);
    expect(find.text('Desk strip runs firmware $_current.'), findsOneWidget);
    expect(host.awake, <bool>[true, false]);
    expect(d.model('Desk strip').runningVersion, _current);
    expect(d.model('Desk strip').restarts, 1);
    expect(
      d.app.registry.byId(d.id('Desk strip'))!.identity!.firmwareVersion,
      _current,
    );

    await t.tap(_key('update-done'));
    await _settle(t, 1);
    expect(find.byType(UpdateFirmwareScreen), findsNothing);
    expect(find.text('1 light has an update'), findsNothing);
    expect(_key('tile-update-badge'), findsNothing);
    expect(find.text('Updating…'), findsNothing);
    await DemoApp.shutDown(t);
  });

  testWidgets('cancel stops safely; the light keeps its firmware', (
    WidgetTester t,
  ) async {
    final DemoApp d = await start(t);
    connect(d, 'Desk strip');
    await _settle(t);
    await push(t, UpdateFirmwareScreen(fixtureId: d.id('Desk strip')));
    await startUpdate(t);
    await _settle(t, 1);
    expect(find.text('Sending the firmware…'), findsOneWidget);
    await t.tap(_key('update-cancel'));
    await _settle(t, 1);
    expect(
      find.text('Update cancelled. Desk strip keeps its current firmware.'),
      findsOneWidget,
    );
    expect(_key('update-retry'), findsOneWidget);
    expect(host.awake, <bool>[true, false]);
    expect(d.model('Desk strip').runningVersion, '3.7.0');
    expect(d.model('Desk strip').ota.active, isFalse);
    expect(d.model('Desk strip').ota.canResume, isFalse);
    expect(d.session('Desk strip').status.updating, isFalse);
    expect(d.session('Desk strip').status.isReady, isTrue);

    // Back on Home it still has its update.
    pop(t, UpdateFirmwareScreen);
    await _settle(t, 1);
    expect(find.text('1 light has an update'), findsOneWidget);
    await DemoApp.shutDown(t);
  });

  testWidgets('a rollback is shown as such', (WidgetTester t) async {
    final DemoApp d = await start(t);
    connect(d, 'Desk strip');
    await _settle(t);
    d.model('Desk strip').failSelfCheck = true;
    await push(t, UpdateFirmwareScreen(fixtureId: d.id('Desk strip')));
    await startUpdate(t);
    await _settle(t, 45);
    expect(
      find.text(
        "The update didn't take; your light is back on its previous firmware.",
      ),
      findsOneWidget,
    );
    expect(_key('update-retry'), findsOneWidget);
    expect(d.model('Desk strip').runningVersion, '3.7.0');
    expect(d.model('Desk strip').otaFlash.rolledBack, isTrue);
    await DemoApp.shutDown(t);
  });

  testWidgets('a failure says why and offers Try again', (
    WidgetTester t,
  ) async {
    final DemoApp d = await start(t);
    connect(d, 'Desk strip');
    await _settle(t);
    await push(t, UpdateFirmwareScreen(fixtureId: d.id('Desk strip')));
    await startUpdate(t);
    // The light goes away mid-transfer and does not come back.
    d.radio.setAvailable('demo-rgb', available: false);
    await _settle(t, 40);
    expect(find.text("The update didn't finish"), findsOneWidget);
    expect(
      find.text(
        'Lost the connection to the light. Move closer and try again; it '
        'continues where it stopped.',
      ),
      findsOneWidget,
    );
    expect(_key('update-retry'), findsOneWidget);
    expect(host.awake.last, isFalse);
    await DemoApp.shutDown(t);
  });

  testWidgets('light settings offer the update; up-to-date lights do not', (
    WidgetTester t,
  ) async {
    final DemoApp d = await start(t);
    await push(t, LightSettingsScreen(fixtureId: d.id('Desk strip')));
    await _settle(t);
    await t.scrollUntilVisible(
      _key('settings-update-firmware'),
      200,
      scrollable: find.byType(Scrollable).last,
    );
    expect(
      find.text('Firmware $_current is available (this light has 3.7.0)'),
      findsOneWidget,
    );
    await t.tap(_key('settings-update-firmware'));
    await _settle(t, 1);
    expect(find.byType(UpdateFirmwareScreen), findsOneWidget);
    pop(t, UpdateFirmwareScreen);
    await _settle(t, 1);
    pop(t, LightSettingsScreen);
    await _settle(t, 1);

    await push(t, LightSettingsScreen(fixtureId: d.id('Hallway')));
    await _settle(t);
    expect(_key('settings-update-firmware'), findsNothing);
    await DemoApp.shutDown(t);
  });

  testWidgets('developer page: bundled version and reinstall', (
    WidgetTester t,
  ) async {
    final DemoApp d = await start(t);
    ProviderScope.containerOf(t.element(find.byType(HomeScreen)))
        .read(developerToolsProvider.notifier)
        .set(on: true);
    await push(t, LightDeveloperScreen(fixtureId: d.id('Living room')));
    await _settle(t);
    await t.scrollUntilVisible(
      _key('dev-reinstall'),
      200,
      scrollable: find.byType(Scrollable).last,
    );
    expect(
      find.descendant(
        of: _key('dev-bundled-firmware'),
        matching: find.text(_current),
      ),
      findsOneWidget,
    );
    expect(
      find.text('Sends firmware $_current to this light again'),
      findsOneWidget,
    );
    await t.ensureVisible(_key('dev-reinstall'));
    await t.pump();
    await t.tap(_key('dev-reinstall'));
    await _settle(t, 1);
    expect(find.text('Reinstall firmware'), findsOneWidget);
    expect(
      find.textContaining('gets firmware $_current again'),
      findsOneWidget,
    );
    await startUpdate(t);
    await _settle(t, 35);
    expect(find.text('Updated to $_current'), findsOneWidget);
    expect(d.model('Living room').restarts, 1);
    expect(d.model('Living room').otaFlash.running, 1);

    // Back on the developer page: how the transfer went.
    pop(t, UpdateFirmwareScreen);
    await _settle(t, 1);
    await t.scrollUntilVisible(
      _key('dev-update-stats'),
      200,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.text('Last update transfer'), findsOneWidget);
    expect(
      find.textContaining(
        RegExp(r'^\d+\.\d kB/s · window re-sends: 0 · resumes: 0$'),
      ),
      findsOneWidget,
    );
    await DemoApp.shutDown(t);
  });

  testWidgets('OTA=0: a one-time USB install instead of an update offer', (
    WidgetTester t,
  ) async {
    const String usb =
        'This light needs a one-time USB install to receive updates.';
    final DemoApp d = await start(t);
    final EbDeviceModel m = d.model('Desk strip');
    m.otaFlash.capacity = 0;
    m.reboot();
    connect(d, 'Desk strip');
    await t.runAsync(() => d.app.ble.connections.reconnect(d.id('Desk strip')));
    await _settle(t, 3);
    expect(d.session('Desk strip').status.isReady, isTrue);
    expect(
      d.session('Desk strip').status.view!.firmware!.needsUsbInstall,
      isTrue,
    );
    expect(find.text('1 light has an update'), findsNothing);
    expect(_key('tile-update-badge'), findsNothing);

    await push(t, LightSettingsScreen(fixtureId: d.id('Desk strip')));
    await _settle(t);
    await t.scrollUntilVisible(
      _key('settings-update-firmware'),
      200,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.text(usb), findsOneWidget);
    pop(t, LightSettingsScreen);
    await _settle(t, 1);

    await push(t, UpdateFirmwareScreen(fixtureId: d.id('Desk strip')));
    expect(t.widget<Text>(_key('update-blocked')).data, usb);
    expect(t.widget<FilledButton>(_key('update-start')).onPressed, isNull);
    expect(find.text("This firmware doesn't fit this light."), findsNothing);
    await DemoApp.shutDown(t);
  });

  testWidgets('suspended in the background: the screen says the update '
      'paused; it resumes on return', (WidgetTester t) async {
    final DemoApp d = await start(t);
    connect(d, 'Desk strip');
    await _settle(t);
    await push(t, UpdateFirmwareScreen(fixtureId: d.id('Desk strip')));
    await startUpdate(t);
    expect(find.text('Sending the firmware…'), findsOneWidget);
    final ConnectionManager c = d.app.ble.connections;
    await t.runAsync(c.onBackground);
    await t.runAsync(c.onBackgroundExpiring);
    await _settle(t, 3);
    expect(_key('update-paused'), findsOneWidget);
    expect(
      find.text(
        'The update paused while the app was in the background. It '
        'continues when you return to the app.',
      ),
      findsOneWidget,
    );
    expect(d.session('Desk strip').status.isConnected, isFalse);

    await t.runAsync(c.onForeground);
    await _settle(t, 45);
    expect(find.text('Updated to $_current'), findsOneWidget);
    expect(_key('update-paused'), findsNothing);
    expect(d.model('Desk strip').runningVersion, _current);
    await DemoApp.shutDown(t);
  });

  for (final (String option, String image) in <(String, String)>[
    ('rollback-fails-check', 'fails its check'),
    ('rollback-freezes', 'freezes'),
  ]) {
    testWidgets('debug build: the rollback test image that $image goes back '
        'to the previous firmware on its own', (WidgetTester t) async {
      final DemoApp d = await start(t);
      ProviderScope.containerOf(t.element(find.byType(HomeScreen)))
          .read(developerToolsProvider.notifier)
          .set(on: true);
      await push(t, LightDeveloperScreen(fixtureId: d.id('Living room')));
      await _settle(t);
      await t.scrollUntilVisible(
        _key('dev-rollback-test'),
        200,
        scrollable: find.byType(Scrollable).last,
      );
      await t.ensureVisible(_key('dev-rollback-test'));
      await t.pump();
      expect(find.text('Install rollback test image'), findsOneWidget);
      await t.tap(_key('dev-rollback-test'));
      await _settle(t, 1);
      await t.tap(_key(option));
      await _settle(t, 1);
      expect(find.text('Rollback test'), findsOneWidget);
      expect(find.text('$_current → 3.8.9999'), findsOneWidget);
      await startUpdate(t);
      await _settle(t, 45);
      expect(find.text('Rolled back as expected'), findsOneWidget);
      expect(
        find.text(
          'Living room is back on firmware $_current. DIAG: rb=1, slot 0, '
          'the one it ran before.',
        ),
        findsOneWidget,
      );
      final EbDeviceModel m = d.model('Living room');
      expect(m.runningVersion, _current);
      expect(m.otaFlash.running, 0);
      expect(m.otaFlash.rolledBack, isTrue);
      expect(d.session('Living room').status.isReady, isTrue);
      await DemoApp.shutDown(t);
    });
  }

  testWidgets('never a downgrade', (WidgetTester t) async {
    final DemoApp d = await start(t);
    d.radio.fixtures.add(
      SimFixture.electroBright(id: 'demo-newer', version: '3.9.0'),
    );
    d.app.registry.add(
      Fixture(
        id: 'f-newer',
        deviceId: 'demo-newer',
        name: 'Porch',
        layout: ChannelLayout.rgbw,
        driver: DriverKind.electroBright,
        addedAt: DateTime(2026),
      ),
    );
    connect(d, 'Desk strip');
    final Want w = d.app.ble.connections.want('f-newer', WantReason.screen);
    addTearDown(w.release);
    await _settle(t);
    expect(d.app.ble.connections.session('f-newer')!.status.isReady, isTrue);
    // Only the older light counts.
    expect(find.text('1 light has an update'), findsOneWidget);
    ProviderScope.containerOf(t.element(find.byType(HomeScreen)))
        .read(developerToolsProvider.notifier)
        .set(on: true);
    await push(t, LightDeveloperScreen(fixtureId: 'f-newer'));
    await _settle(t, 1);
    await t.scrollUntilVisible(
      _key('dev-reinstall'),
      200,
      scrollable: find.byType(Scrollable).last,
    );
    expect(
      find.text("This light has newer firmware than this app's ($_current)."),
      findsOneWidget,
    );
    expect(t.widget<ListTile>(_key('dev-reinstall')).enabled, isFalse);
    pop(t, LightDeveloperScreen);
    await _settle(t, 1);
    await push(t, const UpdateFirmwareScreen(fixtureId: 'f-newer'));
    expect(find.text('The light already has newer firmware.'), findsOneWidget);
    expect(t.widget<FilledButton>(_key('update-start')).onPressed, isNull);
    await DemoApp.shutDown(t);
  });

  testWidgets('one light at a time', (WidgetTester t) async {
    final DemoApp d = await start(t);
    connect(d, 'Desk strip');
    connect(d, 'Living room');
    await _settle(t);
    await push(t, UpdateFirmwareScreen(fixtureId: d.id('Desk strip')));
    await startUpdate(t);
    await push(
      t,
      UpdateFirmwareScreen(fixtureId: d.id('Living room'), reinstall: true),
    );
    expect(
      find.text(
        "Another light is updating. You can update this one when it's done.",
      ),
      findsOneWidget,
    );
    expect(t.widget<FilledButton>(_key('update-start')).onPressed, isNull);
    d.app.updates.cancel(d.id('Desk strip'));
    await _settle(t, 1);
    expect(t.widget<FilledButton>(_key('update-start')).onPressed, isNotNull);
    await DemoApp.shutDown(t);
  });

  test('a group row says a light is updating', () {
    final AppLocalizationsEn l = AppLocalizationsEn();
    expect(
      groupRowStatus(
        l,
        LinkPhase.ready,
        included: true,
        own: false,
        limitedOut: false,
        updating: true,
      ),
      'Updating…',
    );
  });

  test('every problem has its own message', () {
    final AppLocalizationsEn l = AppLocalizationsEn();
    final Set<String> texts = <String>{
      for (final UpdateProblem p in UpdateProblem.values)
        updateProblemText(l, p),
    };
    expect(texts.length, UpdateProblem.values.length);
  });
}
