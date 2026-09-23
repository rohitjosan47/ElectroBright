import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

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

/// The Bluetooth stack. Built only after the permission question is settled,
/// because touching the BLE plugin shows the iOS permission prompt.
final class BleStack {
  BleStack._(this.central, this.discovery, this.connections);

  final BleCentral central;
  final Discovery discovery;
  final ConnectionManager connections;

  Future<void> dispose() async {
    await connections.dispose();
    await discovery.dispose();
    final BleCentral c = central;
    if (c is _TracingCentral) {
      final BleCentral inner = c.inner;
      if (inner is SimCentral) inner.dispose();
    }
  }
}

/// App-wide services (one instance, overridden into Riverpod in main).
final class AppServices {
  AppServices({PlatformBridge? platform, Haptics? haptics})
    : platform = platform ?? PlatformBridge(),
      haptics = haptics ?? Haptics();

  final Scheduler scheduler = SystemScheduler();
  final PlatformBridge platform;
  final Haptics haptics;
  final BleTrace trace = BleTrace();
  BleStack? _ble;
  bool _demo = false;

  BleStack? get ble => _ble;
  bool get isDemo => _demo;

  /// Builds (or rebuilds) the BLE stack: the real radio, or simulated demo
  /// lights.
  Future<BleStack> startBle({bool demo = false}) async {
    if (_ble != null && _demo == demo) return _ble!;
    await _ble?.dispose();
    _demo = demo;
    final bool android = Platform.isAndroid;
    final BleCentral inner = demo
        ? SimCentral(
            scheduler: scheduler,
            fixtures: <SimFixture>[
              SimFixture.electroBright(id: 'demo-1'),
              SimFixture.electroBright(
                id: 'demo-2',
                name: 'ElectroBright_C3_V1',
                rssi: -71,
              ),
            ],
          )
        : ReactiveBleCentral();
    final BleCentral central = _TracingCentral(inner, trace);
    final Discovery discovery = Discovery(
      central: central,
      scheduler: scheduler,
      isAndroid: android,
    );
    final ConnectionManager connections = ConnectionManager(
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
  }) async {
    _trace.add('link', 'connect $deviceId');
    try {
      return TracingLink(
        await inner.connect(deviceId, services: services, timeout: timeout),
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
