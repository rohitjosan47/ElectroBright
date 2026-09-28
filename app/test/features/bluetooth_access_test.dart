import 'package:clock/clock.dart';
import 'package:electrobright/app.dart';
import 'package:electrobright/app/app_session.dart';
import 'package:electrobright/app/bluetooth_access.dart';
import 'package:electrobright/bootstrap/service_registry.dart';
import 'package:electrobright/core/ble/ble_central.dart';
import 'package:electrobright/core/model/channel_layout.dart';
import 'package:electrobright/core/model/fixture.dart';
import 'package:electrobright/core/store/json_store.dart';
import 'package:electrobright/core/util/scheduler.dart';
import 'package:electrobright/design/platform/platform_api.g.dart';
import 'package:electrobright/design/platform/platform_bridge.dart';
import 'package:electrobright/features/home/light_tile.dart';
import 'package:electrobright/sim/sim_central.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// The native side: the permission as [auth], what the prompt answers
/// ([grant]), Location Services, and every call made.
final class _Host extends PlatformHostApi {
  _Host({
    this.auth = BluetoothAuthorization.notDetermined,
    this.grant = BluetoothAuthorization.allowed,
  });

  BluetoothAuthorization auth;
  BluetoothAuthorization grant;
  bool locationOff = false;
  int requests = 0;
  int enables = 0;
  final List<String> calls = <String>[];
  final List<SettingsPage> settings = <SettingsPage>[];

  @override
  Future<BluetoothAuthorization> bluetoothAuthorization() async => auth;

  @override
  Future<BluetoothAuthorization> requestBluetoothAuthorization() async {
    requests++;
    calls.add('request');
    return auth = grant;
  }

  @override
  Future<bool> requestEnableBluetooth() async {
    enables++;
    calls.add('enable');
    return true;
  }

  @override
  Future<bool> locationServicesRequiredButOff() async => locationOff;

  @override
  Future<void> openSettings(SettingsPage page) async => settings.add(page);
}

Finder _key(String k) => find.byKey(ValueKey<String>(k));

Future<void> _settle(WidgetTester t, [int seconds = 1]) async {
  for (int i = 0; i < seconds * 10; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

/// The app with real lights on a simulated radio that starts in [adapter],
/// on the onboarding screen.
Future<(AppServices, SimCentral Function())> _launch(
  WidgetTester t,
  _Host host, {
  BleAdapterState adapter = BleAdapterState.ready,
}) async {
  final Stopwatch watch = clock.stopwatch()..start();
  final SystemScheduler scheduler = SystemScheduler(
    elapsed: () => watch.elapsed,
  );
  SimCentral? radio;
  final AppServices services = AppServices(
    scheduler: scheduler,
    platform: PlatformBridge(api: host),
    radio: () => radio = SimCentral(
      scheduler: scheduler,
      fixtures: <SimFixture>[SimFixture.electroBright(id: 'dev0')],
    )..setAdapterState(adapter),
  );
  await t.pumpWidget(
    ProviderScope(
      retry: (int retryCount, Object error) => null,
      overrides: [
        servicesProvider.overrideWithValue(services),
        storeProvider.overrideWithValue(JsonStore.memory()),
        legacyPrefsProvider.overrideWithValue(() async => null),
      ],
      child: ElectroBrightApp(services: services),
    ),
  );
  await t.pump();
  return (services, () => radio!);
}

AppSession _app(WidgetTester t) =>
    ProviderScope.containerOf(t.element(find.byType(ElectroBrightApp)))
        .read(appSessionProvider)!;

void _addLight(AppSession app) => app.registry.add(
  Fixture(
    id: 'f0',
    deviceId: 'dev0',
    name: 'Desk',
    layout: ChannelLayout.rgbw,
    driver: DriverKind.electroBright,
    addedAt: DateTime(2026),
  ),
);

Finder _tileText(String text) =>
    find.descendant(of: find.byType(LightTile), matching: find.text(text));

Future<void> _shutDown(WidgetTester t) async {
  await t.pumpWidget(const SizedBox());
  await t.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 200)),
  );
  await _settle(t);
}

void main() {
  group('BluetoothAccess', () {
    late ManualScheduler clock;
    late SimCentral radio;

    setUp(() {
      clock = ManualScheduler();
      radio = SimCentral(scheduler: clock);
    });
    tearDown(() => radio.dispose());

    Future<void> pump() async {
      for (int i = 0; i < 20; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    test('Android: asks for the permission, then to switch Bluetooth on; '
        'a refusal asks for nothing more', () async {
      final _Host host = _Host();
      final BluetoothAccess a = BluetoothAccess(
        platform: PlatformBridge(api: host),
        central: radio,
        android: true,
      );
      await a.ensure();
      expect(host.calls, <String>['request', 'enable']);

      final _Host refused = _Host(grant: BluetoothAuthorization.denied);
      final BluetoothAccess b = BluetoothAccess(
        platform: PlatformBridge(api: refused),
        central: radio,
        android: true,
      );
      await b.ensure();
      expect(refused.calls, <String>['request']);
      await a.dispose();
      await b.dispose();
    });

    test('Android: the radio reporting unauthorized asks once per report, '
        'not again while it stays so', () async {
      final _Host host = _Host(grant: BluetoothAuthorization.denied);
      final BluetoothAccess a = BluetoothAccess(
        platform: PlatformBridge(api: host),
        central: radio,
        android: true,
      );
      await pump();
      expect(host.requests, 0, reason: 'ready: nothing to ask');
      radio.setAdapterState(BleAdapterState.unauthorized);
      await pump();
      expect(host.requests, 1);
      radio.setAdapterState(BleAdapterState.unauthorized);
      await pump();
      expect(host.requests, 1);
      // Allowed in Settings, later withdrawn: asked again.
      radio.setAdapterState(BleAdapterState.ready);
      await pump();
      radio.setAdapterState(BleAdapterState.unauthorized);
      await pump();
      expect(host.requests, 2);
      expect(host.enables, 0, reason: 'never allowed');
      await a.dispose();
    });

    test('Android 11 and older: Location Services off shows even while the '
        'radio reports ready', () async {
      final _Host host = _Host(auth: BluetoothAuthorization.allowed)
        ..locationOff = true;
      final BluetoothAccess a = BluetoothAccess(
        platform: PlatformBridge(api: host),
        central: radio,
        android: true,
      );
      await a.ensure();
      expect(a.locationOff.value, isTrue);
      expect(host.requests, 0, reason: 'already allowed');
      host.locationOff = false;
      await a.checkLocation();
      expect(a.locationOff.value, isFalse);
      await a.dispose();
    });

    test('iOS asks for nothing: its own prompt appears when Bluetooth '
        'starts', () async {
      final _Host host = _Host();
      final BluetoothAccess a = BluetoothAccess(
        platform: PlatformBridge(api: host),
        central: radio,
        android: false,
      );
      radio.setAdapterState(BleAdapterState.unauthorized);
      await pump();
      await a.ensure();
      expect(host.calls, isEmpty);
      await a.dispose();
    });

    test('each issue has its own action', () async {
      final _Host host = _Host(auth: BluetoothAuthorization.allowed);
      final BluetoothAccess android = BluetoothAccess(
        platform: PlatformBridge(api: host),
        central: radio,
        android: true,
      );
      await android.resolve(BluetoothIssue.off);
      await android.resolve(BluetoothIssue.denied);
      await android.resolve(BluetoothIssue.locationOff);
      await android.resolve(BluetoothIssue.unsupported);
      expect(host.enables, 1);
      expect(host.settings, <SettingsPage>[
        SettingsPage.app,
        SettingsPage.location,
      ]);
      expect(actionFor(BluetoothIssue.off, android: false), isNull);
      expect(
        actionFor(BluetoothIssue.denied, android: false),
        BluetoothIssueAction.openSettings,
      );
      expect(actionFor(BluetoothIssue.unsupported, android: true), isNull);
      await android.dispose();
    });
  });

  testWidgets('Android: "Use my lights" asks for the permission, then to '
      'switch Bluetooth on; each Bluetooth state shows its own notice, '
      'action and light text; Add light shows it instead of searching', (
    WidgetTester t,
  ) async {
    final _Host host = _Host();
    final (AppServices _, SimCentral Function() radio) = await _launch(
      t,
      host,
      adapter: BleAdapterState.unauthorized,
    );
    await t.tap(find.text('Use my lights'));
    await _settle(t);
    expect(host.requests, 1, reason: 'one prompt, not one per trigger');
    expect(host.enables, 1);
    expect(host.calls, <String>['request', 'enable']);
    _addLight(_app(t));
    await _settle(t);

    // Refused (the radio still says unauthorized).
    expect(_key('bluetooth-notice-denied'), findsOneWidget);
    expect(_tileText('Bluetooth permission needed'), findsOneWidget);
    await t.tap(_key('bluetooth-notice-action'));
    await t.pump();
    expect(host.settings, <SettingsPage>[SettingsPage.app]);
    expect(find.text('Open settings'), findsOneWidget);

    radio().setAdapterState(BleAdapterState.poweredOff);
    await _settle(t);
    expect(_key('bluetooth-notice-off'), findsOneWidget);
    expect(_tileText('Bluetooth is off'), findsOneWidget);
    expect(find.text('Turn on Bluetooth'), findsOneWidget);
    await t.tap(_key('bluetooth-notice-action'));
    await t.pump();
    expect(host.enables, 2);

    radio().setAdapterState(BleAdapterState.unsupported);
    await _settle(t);
    expect(_key('bluetooth-notice-unsupported'), findsOneWidget);
    expect(_tileText('Bluetooth not supported'), findsOneWidget);
    expect(_key('bluetooth-notice-action'), findsNothing);

    // Android 11 and older: the radio is on, Location Services are not.
    host.locationOff = true;
    radio().setAdapterState(BleAdapterState.ready);
    await _settle(t);
    expect(_key('bluetooth-notice-locationOff'), findsOneWidget);
    await t.tap(_key('bluetooth-notice-action'));
    await t.pump();
    expect(host.settings.last, SettingsPage.location);

    // Add light says why nothing can be found.
    await t.tap(find.text('Add light'));
    await _settle(t);
    expect(_key('bluetooth-notice-locationOff'), findsOneWidget);
    expect(find.text('Looking for lights…'), findsNothing);
    // Location Services switched on in Settings; back in the app.
    host.locationOff = false;
    await _app(t).bluetooth!.checkLocation();
    await _settle(t);
    expect(_key('bluetooth-notice-locationOff'), findsNothing);
    await t.tap(find.byIcon(Icons.close_rounded));
    await _settle(t, 2);
    expect(_tileText('Connected'), findsOneWidget);
    await _shutDown(t);
  });

  testWidgets('iOS: nothing is requested (the system prompts); a refusal '
      'offers Settings, Bluetooth off explains Control Centre', (
    WidgetTester t,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      final _Host host = _Host();
      final (AppServices _, SimCentral Function() radio) = await _launch(
        t,
        host,
        adapter: BleAdapterState.unauthorized,
      );
      await t.tap(find.text('Use my lights'));
      await _settle(t);
      expect(host.calls, isEmpty);
      expect(_key('bluetooth-notice-denied'), findsOneWidget);
      await t.tap(_key('bluetooth-notice-action'));
      await t.pump();
      expect(host.settings, <SettingsPage>[SettingsPage.app]);

      radio().setAdapterState(BleAdapterState.poweredOff);
      await _settle(t);
      expect(_key('bluetooth-notice-off'), findsOneWidget);
      expect(find.textContaining('Control Centre'), findsOneWidget);
      expect(_key('bluetooth-notice-action'), findsNothing);
      await _shutDown(t);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
