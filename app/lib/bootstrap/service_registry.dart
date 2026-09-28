import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/protocol/eb/eb_fixture_catalog.dart';
import '../core/ble/ble_central.dart';
import '../core/ble/ble_link.dart';
import '../core/ble/ble_trace.dart';
import '../core/ble/reactive_ble_central.dart';
import '../core/util/scheduler.dart';
import '../design/haptics/haptics.dart';
import '../design/platform/platform_bridge.dart';
import '../drivers/electrobright/eb_session.dart';
import '../sessions/connection_manager.dart';
import '../sessions/discovery.dart';
import '../sim/sim_central.dart';

/// The firmware the demo's RGB light runs: older than the app's bundled
/// firmware, so demo mode can show a wireless update.
const String demoOlderFirmware = '3.7.0';

/// The Bluetooth stack. Built only after the permission question is settled,
/// because touching the BLE plugin shows the iOS permission prompt.
final class BleStack {
  BleStack._(this.central, this.discovery, this.connections);

  final BleCentral central;
  final Discovery discovery;
  final ConnectionManager connections;

  Future<void> dispose() async {
    // Everything that runs on timers stops now; the rest winds down after.
    connections.halt();
    discovery.halt();
    final BleCentral c = central;
    final BleCentral inner = c is _TracingCentral ? c.inner : c;
    if (inner is SimCentral) inner.dispose();
    await connections.dispose();
    await discovery.dispose();
  }
}

/// App-wide services (one instance, overridden into Riverpod in main).
final class AppServices {
  AppServices({
    PlatformBridge? platform,
    Haptics? haptics,
    Scheduler? scheduler,
    BleCentral Function()? radio,
  }) : platform = platform ?? PlatformBridge(),
       haptics = haptics ?? Haptics(),
       scheduler = scheduler ?? SystemScheduler(),
       _radio = radio ?? ReactiveBleCentral.new;

  final Scheduler scheduler;
  final PlatformBridge platform;
  final Haptics haptics;
  final BleTrace trace = BleTrace();

  /// Makes the real radio (tests pass a simulated one).
  final BleCentral Function() _radio;
  BleStack? _ble;
  bool _demo = false;

  BleStack? get ble => _ble;
  bool get isDemo => _demo;

  /// The simulated lights while in demo mode (tests read their state).
  SimCentral? get demoLights => _demoLights;
  SimCentral? _demoLights;

  /// Stops the BLE stack (app shutdown, tests).
  Future<void> stopBle() async {
    final BleStack? b = _ble;
    _ble = null;
    await b?.dispose();
  }

  /// Builds (or rebuilds) the BLE stack: the real radio, or simulated demo
  /// lights.
  Future<BleStack> startBle({bool demo = false}) async {
    if (_ble != null && _demo == demo) return _ble!;
    await _ble?.dispose();
    _demo = demo;
    final bool android = Platform.isAndroid;
    final SimCentral? sim = demo
        ? SimCentral(
            scheduler: scheduler,
            // One demo light of every fixture type.
            fixtures: <SimFixture>[
              SimFixture.electroBright(id: 'demo-rgbw'),
              // Runs older firmware, so a wireless update can be tried
              // (a fast simulated transfer of the bundled image).
              SimFixture.electroBright(
                id: 'demo-rgb',
                fixture: EbFixtureCatalog.rgb,
                rssi: -64,
                version: demoOlderFirmware,
              ),
              SimFixture.electroBright(
                id: 'demo-rgbcct',
                fixture: EbFixtureCatalog.rgbcct,
                rssi: -61,
              ),
              SimFixture.electroBright(
                id: 'demo-cct',
                fixture: EbFixtureCatalog.cct,
                rssi: -70,
              ),
              SimFixture.electroBright(
                id: 'demo-w',
                fixture: EbFixtureCatalog.w,
                rssi: -74,
              ),
              // A light that still needs the 3.x firmware.
              SimFixture.legacy(id: 'demo-legacy'),
            ],
          )
        : null;
    _demoLights = sim;
    final BleCentral inner = sim ?? _radio();
    // Traced for the BLE Lab, which only debug builds show.
    final BleCentral central = kDebugMode
        ? _TracingCentral(inner, trace)
        : inner;
    final Discovery discovery = Discovery(
      central: central,
      scheduler: scheduler,
      isAndroid: android,
    );
    late final ConnectionManager connections;
    // Saved lights are never forgotten.
    discovery.keep = (String id) => connections.manages(id);
    connections = ConnectionManager(
      central: central,
      discovery: discovery,
      scheduler: scheduler,
      policy: ConnectionPolicy(
        isAndroid: android,
        sessionOptions: EbSessionOptions(
          frameGap: android
              ? const Duration(milliseconds: 16)
              : const Duration(milliseconds: 25),
        ),
      ),
      backgroundTasks: platform,
    );
    platform.onTaskExpiring = (_) =>
        unawaited(connections.onBackgroundExpiring());
    return _ble = BleStack._(central, discovery, connections);
  }
}

final Provider<AppServices> servicesProvider = Provider<AppServices>(
  (Ref ref) => throw UnimplementedError('overridden in main()'),
);

/// Wraps a central so every link is traced (diagnostics, BLE Lab export).
final class _TracingCentral implements BleCentral {
  _TracingCentral(this.inner, this._trace);
  final BleCentral inner;
  final BleTrace _trace;

  @override
  Stream<BleAdapterState> get adapterState => inner.adapterState;
  @override
  BleAdapterState get currentAdapterState => inner.currentAdapterState;
  @override
  Stream<Advertisement> scan({
    List<String> services = const <String>[],
    ScanIntensity intensity = ScanIntensity.balanced,
  }) => inner.scan(services: services, intensity: intensity);

  @override
  Future<BleLink> connect(
    String deviceId, {
    required Map<String, List<String>> services,
    Duration? timeout,
    Future<void>? cancel,
  }) async {
    _trace.add('link', 'connect $deviceId');
    try {
      return TracingLink(
        await inner.connect(
          deviceId,
          services: services,
          timeout: timeout,
          cancel: cancel,
        ),
        _trace,
      );
    } on Object catch (e) {
      _trace.add('link', 'connect failed: $e');
      rethrow;
    }
  }

  @override
  Future<void> clearCache(String deviceId) => inner.clearCache(deviceId);
}
