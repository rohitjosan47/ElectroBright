import 'package:clock/clock.dart';
import 'package:electrobright/app.dart';
import 'package:electrobright/app/app_session.dart';
import 'package:electrobright/bootstrap/service_registry.dart';
import 'package:electrobright/core/model/channel_layout.dart';
import 'package:electrobright/core/model/fixture.dart';
import 'package:electrobright/core/protocol/eb/eb_fixture_catalog.dart';
import 'package:electrobright/core/protocol/eb/eb_scene.dart';
import 'package:electrobright/core/store/json_store.dart';
import 'package:electrobright/core/util/scheduler.dart';
import 'package:electrobright/features/control/control_screen.dart';
import 'package:electrobright/sessions/fixture_session.dart';
import 'package:electrobright/sim/eb_device_model.dart';
import 'package:electrobright/sim/sim_central.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// The app in demo mode with one saved light of every fixture type (or the
/// lights given to [start]).
final class DemoApp {
  DemoApp._(this.services, this.app, this._lights);

  /// Saved demo lights: name -> (simulated device id, layout).
  static const Map<String, (String, ChannelLayout)> lights =
      <String, (String, ChannelLayout)>{
        'Living room': ('demo-rgbw', ChannelLayout.rgbw),
        'Desk strip': ('demo-rgb', ChannelLayout.rgb),
        'Bedroom': ('demo-rgbcct', ChannelLayout.rgbcct),
        'Kitchen': ('demo-cct', ChannelLayout.cct),
        'Hallway': ('demo-w', ChannelLayout.w),
      };

  /// The groups: an RGB, two identical RGBW lights (same type and
  /// firmware), a tunable white and a single white.
  static const Map<String, (String, ChannelLayout)> groupLights =
      <String, (String, ChannelLayout)>{
        'Desk strip': ('demo-rgb', ChannelLayout.rgb),
        'Living room': ('demo-rgbw', ChannelLayout.rgbw),
        'Reading lamp': ('demo-rgbw-2', ChannelLayout.rgbw),
        'Kitchen': ('demo-cct', ChannelLayout.cct),
        'Hallway': ('demo-w', ChannelLayout.w),
      };

  final AppServices services;
  final AppSession app;
  final Map<String, (String, ChannelLayout)> _lights;

  /// Pumps [seconds] of app time in 100 ms frames.
  static Future<void> settle(WidgetTester t, [int seconds = 2]) async {
    for (int i = 0; i < seconds * 10; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
  }

  /// Starts demo mode, adds every light and returns on Home. A light whose
  /// simulated device the demo does not have gets one of its type.
  static Future<DemoApp> start(
    WidgetTester t, {
    Map<String, (String, ChannelLayout)> lights = DemoApp.lights,
  }) async {
    // App time follows the test's fake timers.
    final Stopwatch watch = clock.stopwatch()..start();
    final AppServices services = AppServices(
      scheduler: SystemScheduler(elapsed: () => watch.elapsed),
    );
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
    final SimCentral radio = services.demoLights!;
    for (final MapEntry<String, (String, ChannelLayout)> e in lights.entries) {
      if (!radio.fixtures.any((SimFixture f) => f.id == e.value.$1)) {
        radio.fixtures.add(
          SimFixture.electroBright(
            id: e.value.$1,
            fixture: EbFixtureCatalog.forLayout(e.value.$2),
          ),
        );
      }
      app.registry.add(
        Fixture(
          id: _idOf(e.value.$1),
          deviceId: e.value.$1,
          name: e.key,
          layout: e.value.$2,
          driver: DriverKind.electroBright,
          addedAt: DateTime(2026),
        ),
      );
    }
    await settle(t, 1);
    return DemoApp._(services, app, lights);
  }

  static String _idOf(String deviceId) => 'f-$deviceId';

  /// The fixture id of a default demo light.
  static String idOf(String name) => _idOf(lights[name]!.$1);

  /// The fixture id of [name] among this app's lights.
  String id(String name) => _idOf(_lights[name]!.$1);

  /// Opens [name]'s control screen from Home; it connects.
  Future<void> open(WidgetTester t, String name) async {
    await t.scrollUntilVisible(
      find.text(name),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    // Built past the fold (lazy lists build ahead): bring it on screen.
    await t.ensureVisible(find.text(name));
    await t.pump();
    await t.tap(find.text(name));
    await settle(t);
    expect(find.byType(ControlScreen), findsOneWidget);
    expect(
      session(name).status.phase,
      LinkPhase.ready,
      reason: '$name connects while its screen is open',
    );
  }

  FixtureSession session(String name) => app.ble.connections.session(id(name))!;

  /// The simulated light (the firmware twin).
  EbDeviceModel model(String name) => services.demoLights!.fixtures
      .firstWhere((SimFixture f) => f.id == _lights[name]!.$1)
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
