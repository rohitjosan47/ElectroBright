import 'package:electrobright/app.dart';
import 'package:electrobright/app/app_session.dart';
import 'package:electrobright/bootstrap/service_registry.dart';
import 'package:electrobright/core/model/channel_layout.dart';
import 'package:electrobright/core/model/fixture.dart';
import 'package:electrobright/core/protocol/eb/eb_scene.dart';
import 'package:electrobright/core/store/json_store.dart';
import 'package:electrobright/features/control/control_screen.dart';
import 'package:electrobright/sessions/fixture_session.dart';
import 'package:electrobright/sim/eb_device_model.dart';
import 'package:electrobright/sim/sim_central.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// The app in demo mode with one saved light of every fixture type.
final class DemoApp {
  DemoApp._(this.services, this.app);

  /// Saved demo lights: name -> (simulated device id, layout).
  static const Map<String, (String, ChannelLayout)> lights =
      <String, (String, ChannelLayout)>{
        'Living room': ('demo-rgbw', ChannelLayout.rgbw),
        'Desk strip': ('demo-rgb', ChannelLayout.rgb),
        'Bedroom': ('demo-rgbcct', ChannelLayout.rgbcct),
        'Kitchen': ('demo-cct', ChannelLayout.cct),
        'Hallway': ('demo-w', ChannelLayout.w),
      };

  final AppServices services;
  final AppSession app;

  /// Pumps [seconds] of app time in 100 ms frames.
  static Future<void> settle(WidgetTester t, [int seconds = 2]) async {
    for (int i = 0; i < seconds * 10; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
  }

  /// Starts demo mode, adds every light and returns on Home.
  static Future<DemoApp> start(WidgetTester t) async {
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
    await t.pump();
    await t.tap(find.text('Try demo lights'));
    await settle(t, 1);
    final AppSession app = ProviderScope.containerOf(
      t.element(find.text('Lights')),
    ).read(appSessionProvider)!;
    for (final MapEntry<String, (String, ChannelLayout)> e in lights.entries) {
      app.registry.add(
        Fixture(
          id: idOf(e.key),
          deviceId: e.value.$1,
          name: e.key,
          layout: e.value.$2,
          driver: DriverKind.electroBright,
          addedAt: DateTime(2026),
        ),
      );
    }
    await settle(t, 1);
    return DemoApp._(services, app);
  }

  static String idOf(String name) => 'f-${lights[name]!.$1}';

  /// Opens [name]'s control screen from Home; it connects.
  Future<void> open(WidgetTester t, String name) async {
    await t.scrollUntilVisible(
      find.text(name),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await t.tap(find.text(name));
    await settle(t);
    expect(find.byType(ControlScreen), findsOneWidget);
    expect(
      session(name).status.phase,
      LinkPhase.ready,
      reason: '$name connects while its screen is open',
    );
  }

  FixtureSession session(String name) =>
      app.ble.connections.session(idOf(name))!;

  /// The simulated light (the firmware twin).
  EbDeviceModel model(String name) => services.demoLights!.fixtures
      .firstWhere((SimFixture f) => f.id == lights[name]!.$1)
      .model;

  /// The simulated light's scene.
  EbScene twin(String name) => model(name).scene;

  SimCentral get radio => services.demoLights!;

  /// Shuts the app down (saves, then stops the simulated radio).
  static Future<void> shutDown(WidgetTester t) async {
    await t.pumpWidget(const SizedBox());
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await settle(t, 1);
  }
}
