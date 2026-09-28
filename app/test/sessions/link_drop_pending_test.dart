import 'dart:async';
import 'dart:typed_data';

import 'package:electrobright/core/ble/ble_central.dart';
import 'package:electrobright/core/ble/ble_link.dart';
import 'package:electrobright/core/model/channel_layout.dart';
import 'package:electrobright/core/model/fixture.dart';
import 'package:electrobright/core/protocol/eb/eb_constants.dart';
import 'package:electrobright/core/store/json_store.dart';
import 'package:electrobright/core/util/scheduler.dart';
import 'package:electrobright/drivers/electrobright/eb_session.dart';
import 'package:electrobright/drivers/electrobright/eb_types.dart';
import 'package:electrobright/sessions/connection_manager.dart';
import 'package:electrobright/sessions/discovery.dart';
import 'package:electrobright/sessions/fixture_registry.dart';
import 'package:electrobright/sessions/fixture_session.dart';
import 'package:electrobright/sim/sim_central.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _pump([int n = 20]) async {
  for (int i = 0; i < n; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// The simulated radio, except that a fence PING can be swallowed (it never
/// reaches the light, so it is never answered) and the link then dropped.
final class _Radio implements BleCentral {
  _Radio(this.sim, this.clock);
  final SimCentral sim;
  final ManualScheduler clock;

  /// Swallow the next PING and drop the link [dropAfter] later.
  bool dropAtPing = false;
  Duration dropAfter = const Duration(milliseconds: 100);
  int pings = 0;

  @override
  Stream<BleAdapterState> get adapterState => sim.adapterState;
  @override
  BleAdapterState get currentAdapterState => sim.currentAdapterState;
  @override
  Stream<Advertisement> scan({
    List<String> services = const <String>[],
    ScanIntensity intensity = ScanIntensity.balanced,
  }) => sim.scan(services: services, intensity: intensity);
  @override
  Future<BleLink> connect(
    String deviceId, {
    required Map<String, List<String>> services,
    Duration? timeout,
    Future<void>? cancel,
  }) async => _TapLink(
    await sim.connect(
      deviceId,
      services: services,
      timeout: timeout,
      cancel: cancel,
    ),
    this,
  );
  @override
  Future<void> clearCache(String deviceId) => sim.clearCache(deviceId);
}

final class _TapLink implements BleLink {
  _TapLink(this._inner, this._radio);
  final BleLink _inner;
  final _Radio _radio;

  @override
  String get deviceId => _inner.deviceId;
  @override
  int get mtu => _inner.mtu;
  @override
  bool offers(String serviceUuid) => _inner.offers(serviceUuid);
  @override
  Future<LinkLossReason> get closed => _inner.closed;
  @override
  Stream<Uint8List> subscribe(GattRef ref) => _inner.subscribe(ref);

  @override
  Future<void> write(
    GattRef ref,
    Uint8List value, {
    required bool withResponse,
  }) async {
    if (ref.characteristic == Eb.rxUuid &&
        String.fromCharCodes(value) == 'PING\n') {
      _radio.pings++;
      if (_radio.dropAtPing) {
        _radio.dropAtPing = false;
        _radio.clock.after(_radio.dropAfter, () {
          _radio.sim.setAvailable(deviceId, available: false);
          _radio.clock.after(const Duration(seconds: 1), () {
            _radio.sim.setAvailable(deviceId, available: true);
          });
        });
        return; // "written", never answered
      }
    }
    return _inner.write(ref, value, withResponse: withResponse);
  }

  @override
  Future<void> disconnect() => _inner.disconnect();
}

/// Fenced commands (PRESET_SAVE, PRESET_LOAD, FACTORY_RESET, a resync's
/// STATUS) whose link drops while they wait for their fence PING complete
/// as disconnected; nothing is left waiting, and the light is driven
/// normally once it is back.
void main() {
  late ManualScheduler clock;
  late SimCentral sim;
  late _Radio radio;
  late Discovery discovery;
  late ConnectionManager manager;
  late FixtureRegistry registry;
  late Want want;

  Future<void> run(Duration d) async {
    const Duration step = Duration(milliseconds: 10);
    for (Duration t = Duration.zero; t < d; t += step) {
      await _pump(3);
      clock.advance(step);
    }
    await _pump();
  }

  /// [f]'s value once it completes within [limit] of app time, else null.
  Future<T?> within<T>(Future<T> f, Duration limit) async {
    T? value;
    bool done = false;
    unawaited(
      f.then((T v) {
        value = v;
        done = true;
      }),
    );
    const Duration step = Duration(milliseconds: 10);
    for (Duration t = Duration.zero; t < limit && !done; t += step) {
      await _pump(3);
      clock.advance(step);
    }
    await _pump();
    return value;
  }

  setUp(() async {
    clock = ManualScheduler();
    sim = SimCentral(
      scheduler: clock,
      fixtures: <SimFixture>[SimFixture.electroBright(id: 'dev1')],
    );
    radio = _Radio(sim, clock);
    discovery = Discovery(central: radio, scheduler: clock, isAndroid: false);
    manager = ConnectionManager(
      central: radio,
      discovery: discovery,
      scheduler: clock,
      policy: ConnectionPolicy(isAndroid: false),
    );
    registry = FixtureRegistry(store: JsonStore.memory(), connections: manager);
    registry.add(
      Fixture(
        id: 'f1',
        deviceId: 'dev1',
        name: 'f1',
        layout: ChannelLayout.rgbw,
        driver: DriverKind.electroBright,
        addedAt: DateTime(2026),
      ),
    );
    want = manager.want('f1', WantReason.screen);
    await run(const Duration(seconds: 3));
    expect(manager.session('f1')!.status.isReady, isTrue);
  });

  tearDown(() async {
    want.release();
    await registry.dispose();
    await manager.dispose();
    await discovery.dispose();
    sim.dispose();
  });

  Future<void> dropsAtPing(
    Future<EbResult> Function(FixtureSession s) send,
  ) async {
    final FixtureSession s = manager.session('f1')!;
    radio.dropAtPing = true;
    final int pings = radio.pings;
    final EbResult? r = await within(send(s), const Duration(seconds: 2));
    expect(radio.pings, pings + 1, reason: 'it was waiting for its PING');
    expect(r, isNotNull, reason: 'completed when the link dropped');
    expect(r!.outcome, EbOutcome.disconnected);
    // Back, and driven normally.
    await run(const Duration(seconds: 4));
    expect(s.status.isReady, isTrue);
    expect(
      (await within(s.setMode(3), const Duration(seconds: 1)))?.outcome,
      EbOutcome.ok,
    );
  }

  test('PRESET_SAVE', () async {
    await dropsAtPing(
      (FixtureSession s) =>
          s.presetSave(0).then((EbPresetResult p) => p.result),
    );
  });

  test('PRESET_LOAD', () async {
    await dropsAtPing(
      (FixtureSession s) =>
          s.presetLoad(1).then((EbPresetResult p) => p.result),
    );
  });

  test('FACTORY_RESET', () async {
    await dropsAtPing((FixtureSession s) => s.factoryReset());
  });

  test('a resync (fenced STATUS) ends; the session is closed, not stuck '
      'resyncing', () async {
    final EbSession es = manager.session('f1')!.session!;
    radio.dropAtPing = true;
    bool done = false;
    unawaited(es.resync().then((_) => done = true));
    await run(const Duration(seconds: 1));
    expect(done, isTrue);
    expect(es.phase, EbPhase.closed);
  });
}
