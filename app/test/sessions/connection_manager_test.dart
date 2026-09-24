import 'package:electrobright/core/ble/ble_central.dart';
import 'package:electrobright/core/model/fixture.dart';
import 'package:electrobright/core/model/rgbw.dart';
import 'package:electrobright/core/util/scheduler.dart';
import 'package:electrobright/sessions/connection_manager.dart';
import 'package:electrobright/sessions/discovery.dart';
import 'package:electrobright/sessions/fixture_session.dart';
import 'package:electrobright/sim/sim_central.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _pump([int n = 30]) async {
  for (int i = 0; i < n; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

final class _World {
  _World({bool android = false, int lights = 1}) {
    central = SimCentral(
      scheduler: clock,
      fixtures: <SimFixture>[
        for (int i = 0; i < lights; i++) SimFixture.electroBright(id: 'dev$i'),
      ],
    );
    discovery = Discovery(
      central: central,
      scheduler: clock,
      isAndroid: android,
    );
    manager = ConnectionManager(
      central: central,
      discovery: discovery,
      scheduler: clock,
      policy: ConnectionPolicy(isAndroid: android),
    );
    for (int i = 0; i < lights; i++) {
      manager.register(
        Fixture(
          id: 'f$i',
          deviceId: 'dev$i',
          name: 'Light $i',
          kind: FixtureKind.rgbw,
          driver: DriverKind.electroBright,
          addedAt: DateTime(2026),
        ),
      );
    }
  }

  final ManualScheduler clock = ManualScheduler();
  late final SimCentral central;
  late final Discovery discovery;
  late final ConnectionManager manager;

  FixtureSession s(int i) => manager.session('f$i')!;

  /// Advances virtual time in small steps, letting async work run.
  Future<void> run(Duration d) async {
    const Duration step = Duration(milliseconds: 10);
    for (Duration t = Duration.zero; t < d; t += step) {
      await _pump(5);
      clock.advance(step);
    }
    await _pump();
  }

  Future<void> dispose() async {
    await manager.dispose();
    await discovery.dispose();
    central.dispose();
  }
}

void main() {
  test(
    'a want connects and handshakes; releasing it disconnects after the grace',
    () async {
      final _World w = _World();
      await w.run(const Duration(milliseconds: 50));
      expect(w.s(0).status.phase, LinkPhase.idle);
      final Want want = w.manager.want('f0', WantReason.screen);
      await w.run(const Duration(seconds: 1));
      expect(w.s(0).status.phase, LinkPhase.ready);
      expect(w.s(0).status.view!.firmware!.version.version, '3.5.0');
      want.release();
      await w.run(const Duration(seconds: 30));
      expect(
        w.central.fixtures.first.connected,
        isTrue,
        reason: 'still in grace',
      );
      await w.run(const Duration(seconds: 31));
      expect(w.central.fixtures.first.connected, isFalse);
      expect(w.s(0).status.phase, LinkPhase.idle);
      await w.dispose();
    },
  );

  test(
    'out of range: reconnects when the light returns, replaying fresh changes',
    () async {
      final _World w = _World();
      w.manager.want('f0', WantReason.screen);
      await w.run(const Duration(seconds: 1));
      w.central.setAvailable('dev0', available: false);
      await w.run(const Duration(milliseconds: 100));
      expect(w.s(0).status.phase, isNot(LinkPhase.ready));
      expect(
        w.s(0).status.lastKnown,
        isNotNull,
        reason: 'last state kept for the UI',
      );
      w.s(0).setColor(const Rgbw(9, 8, 7, 6)); // made while reconnecting
      unawaited(w.s(0).setMode(7));
      await w.run(const Duration(seconds: 3));
      w.central.setAvailable('dev0', available: true);
      await w.run(const Duration(seconds: 5));
      expect(w.s(0).status.phase, LinkPhase.ready);
      await w.run(const Duration(seconds: 1));
      final model = w.central.fixtures.first.model;
      expect(model.scene.color, const Rgbw(9, 8, 7, 6));
      expect(model.scene.mode, 7);
      await w.dispose();
    },
  );

  test('offline changes older than 10 s are dropped', () async {
    final _World w = _World();
    w.manager.want('f0', WantReason.screen);
    await w.run(const Duration(seconds: 1));
    w.central.setAvailable('dev0', available: false);
    await w.run(const Duration(milliseconds: 100));
    unawaited(w.s(0).setMode(9));
    await w.run(const Duration(seconds: 12));
    w.central.setAvailable('dev0', available: true);
    await w.run(const Duration(seconds: 40));
    expect(w.s(0).status.phase, LinkPhase.ready);
    expect(w.central.fixtures.first.model.scene.mode, 1);
    await w.dispose();
  });

  test('a missing light becomes unavailable but keeps retrying', () async {
    final _World w = _World();
    w.central.setAvailable('dev0', available: false);
    w.manager.want('f0', WantReason.favourite);
    await w.run(const Duration(seconds: 50));
    expect(w.s(0).status.phase, LinkPhase.unavailable);
    w.central.setAvailable('dev0', available: true);
    await w.run(const Duration(seconds: 35));
    expect(w.s(0).status.phase, LinkPhase.ready);
    await w.dispose();
  });

  test('Bluetooth off pauses everything; on again reconnects', () async {
    final _World w = _World();
    w.manager.want('f0', WantReason.screen);
    await w.run(const Duration(seconds: 1));
    w.central.setAdapterState(BleAdapterState.poweredOff);
    await w.run(const Duration(seconds: 2));
    expect(w.s(0).status.phase, LinkPhase.bluetoothOff);
    w.central.setAdapterState(BleAdapterState.ready);
    await w.run(const Duration(seconds: 3));
    expect(w.s(0).status.phase, LinkPhase.ready);
    await w.dispose();
  });

  test(
    'background releases the lights after 20 s; foreground reconnects',
    () async {
      final _World w = _World(lights: 2);
      w.manager.want('f0', WantReason.screen);
      w.manager.want('f1', WantReason.favourite);
      await w.run(const Duration(seconds: 2));
      expect(w.s(0).status.phase, LinkPhase.ready);
      expect(w.s(1).status.phase, LinkPhase.ready);
      await w.manager.onBackground();
      await w.run(const Duration(seconds: 19));
      expect(w.central.fixtures.every((SimFixture f) => f.connected), isTrue);
      await w.run(const Duration(seconds: 2));
      expect(w.central.fixtures.any((SimFixture f) => f.connected), isFalse);
      await w.manager.onForeground();
      await w.run(const Duration(seconds: 3));
      expect(w.s(0).status.phase, LinkPhase.ready);
      expect(w.s(1).status.phase, LinkPhase.ready);
      await w.dispose();
    },
  );

  test(
    'Android waits for an advert and connects one light at a time',
    () async {
      final _World w = _World(android: true, lights: 3);
      for (int i = 0; i < 3; i++) {
        w.manager.want('f$i', WantReason.favourite);
      }
      await w.run(const Duration(seconds: 5));
      for (int i = 0; i < 3; i++) {
        expect(w.s(i).status.phase, LinkPhase.ready, reason: 'light $i');
      }
      expect(w.discovery.scanStarts, lessThanOrEqualTo(4));
      await w.dispose();
    },
  );
}

void unawaited(Future<Object?> f) {}
