import 'dart:async';

import 'package:electrobright/core/ble/ble_central.dart';
import 'package:electrobright/core/ble/ble_link.dart';
import 'package:electrobright/core/model/fixture.dart';
import 'package:electrobright/core/model/channel_color.dart';
import 'package:electrobright/core/model/channel_layout.dart';
import 'package:electrobright/core/util/scheduler.dart';
import 'package:electrobright/drivers/electrobright/eb_types.dart';
import 'package:electrobright/sessions/connection_manager.dart';
import 'package:electrobright/sessions/discovery.dart';
import 'package:electrobright/sessions/fixture_session.dart';
import 'package:electrobright/sim/eb_device_model.dart';
import 'package:electrobright/sim/sim_central.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _pump([int n = 30]) async {
  for (int i = 0; i < n; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// Advertises like the simulated radio; refuses every connect while
/// [refuse] (a light that is seen but won't take a connection).
final class _RefusingCentral implements BleCentral {
  _RefusingCentral(this.inner);
  final SimCentral inner;
  bool refuse = false;
  int connects = 0;

  /// Links established.
  int links = 0;

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
    connects++;
    if (refuse) throw const ConnectException('refused');
    final BleLink link = await inner.connect(
      deviceId,
      services: services,
      timeout: timeout,
      cancel: cancel,
    );
    links++;
    return link;
  }

  @override
  Future<void> clearCache(String deviceId) => inner.clearCache(deviceId);
}

final class _World {
  _World({bool android = false, int lights = 1}) {
    central = SimCentral(
      scheduler: clock,
      fixtures: <SimFixture>[
        for (int i = 0; i < lights; i++) SimFixture.electroBright(id: 'dev$i'),
      ],
    );
    radio = _RefusingCentral(central);
    discovery = Discovery(central: radio, scheduler: clock, isAndroid: android);
    manager = ConnectionManager(
      central: radio,
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
          layout: ChannelLayout.rgbw,
          driver: DriverKind.electroBright,
          addedAt: DateTime(2026),
        ),
      );
    }
  }

  final ManualScheduler clock = ManualScheduler();
  late final SimCentral central;

  /// The radio the app uses (the simulated one, counting links).
  late final _RefusingCentral radio;
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
  for (final bool android in <bool>[false, true]) {
    test('${android ? 'Android' : 'iOS'}: an unsaved candidate dropped and '
        'the same light picked again at once connects, three times in a '
        'row; the old link never closes the new one', () async {
      final _World w = _World(android: android);
      await w.run(const Duration(milliseconds: 500));
      Want? want;
      String? held;
      for (int round = 1; round <= 3; round++) {
        // Back without saving, then the same light again right away: the
        // old candidate's link is still up when the new one is registered.
        want?.release();
        if (held != null) unawaited(w.manager.unregister(held));
        final String id = 'candidate-$round';
        w.manager.register(
          Fixture(
            id: id,
            deviceId: 'dev0',
            name: 'Candidate',
            layout: ChannelLayout.rgbw,
            driver: DriverKind.electroBright,
            addedAt: DateTime(2026),
          ),
        );
        want = w.manager.want(id, WantReason.screen);
        held = id;
        await w.run(const Duration(seconds: 5));
        expect(
          w.manager.session(id)!.status.isReady,
          isTrue,
          reason: 'round $round',
        );
        await w.run(const Duration(seconds: 5));
        expect(
          w.manager.session(id)!.status.isReady,
          isTrue,
          reason: 'round $round stays connected',
        );
      }
      want?.release();
      await w.dispose();
    });
  }

  test(
    'a want connects and handshakes; releasing it disconnects after the grace',
    () async {
      final _World w = _World();
      await w.run(const Duration(milliseconds: 50));
      expect(w.s(0).status.phase, LinkPhase.idle);
      final Want want = w.manager.want('f0', WantReason.screen);
      await w.run(const Duration(seconds: 1));
      expect(w.s(0).status.phase, LinkPhase.ready);
      expect(
        w.s(0).status.view!.firmware!.version.version,
        EbDeviceModel.firmwareVersion,
      );
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
      w.s(0).setColor(ChannelColor.rgbw(9, 8, 7, 6)); // made while reconnecting
      unawaited(w.s(0).setMode(7));
      await w.run(const Duration(seconds: 3));
      w.central.setAvailable('dev0', available: true);
      await w.run(const Duration(seconds: 5));
      expect(w.s(0).status.phase, LinkPhase.ready);
      await w.run(const Duration(seconds: 1));
      final model = w.central.fixtures.first.model;
      expect(model.scene.color, ChannelColor.rgbw(9, 8, 7, 6));
      expect(model.scene.mode, 7);
      await w.dispose();
    },
  );

  test(
    'offline changes older than 60 s are dropped, with one message',
    () async {
      final _World w = _World();
      w.manager.want('f0', WantReason.screen);
      await w.run(const Duration(seconds: 1));
      final List<EbEvent> events = <EbEvent>[];
      final StreamSubscription<EbEvent> sub = w.s(0).events.listen(events.add);
      w.central.setAvailable('dev0', available: false);
      await w.run(const Duration(milliseconds: 100));
      unawaited(w.s(0).setMode(9));
      await w.run(const Duration(seconds: 50));
      expect(events.whereType<EbOfflineChangesExpired>(), isEmpty);
      await w.run(const Duration(seconds: 12));
      expect(events.whereType<EbOfflineChangesExpired>(), hasLength(1));
      await sub.cancel();
      w.central.setAvailable('dev0', available: true);
      await w.run(const Duration(seconds: 40));
      expect(w.s(0).status.phase, LinkPhase.ready);
      expect(w.central.fixtures.first.model.scene.mode, 1);
      await w.dispose();
    },
  );

  test(
    'brightness set while not connected is shown, sent if back in 60 s',
    () async {
      final _World w = _World();
      w.manager.want('f0', WantReason.screen);
      await w.run(const Duration(seconds: 1));
      w.central.setAvailable('dev0', available: false);
      await w.run(const Duration(milliseconds: 100));
      w.s(0).setBrightness(60, live: true);
      w.s(0).setBrightness(60);
      // The control keeps what the user chose (no spring back)...
      expect(w.s(0).status.state!.scene.brightness, 60);
      expect(w.s(0).status.state!.sleeping, isFalse);
      // ...while the light is away, within the window.
      await w.run(const Duration(seconds: 30));
      expect(w.s(0).status.state!.scene.brightness, 60);
      w.central.setAvailable('dev0', available: true);
      await w.run(const Duration(seconds: 40));
      expect(w.s(0).status.phase, LinkPhase.ready);
      expect(w.central.fixtures.first.model.scene.brightness, 60);
      expect(w.s(0).status.offlineBrightness, isNull);
      await w.dispose();
    },
  );

  test(
    'an offline brightness that runs out glides back, one message',
    () async {
      final _World w = _World();
      w.manager.want('f0', WantReason.screen);
      await w.run(const Duration(seconds: 1));
      final model = w.central.fixtures.first.model;
      final int real = model.scene.brightness;
      final List<EbEvent> events = <EbEvent>[];
      final StreamSubscription<EbEvent> sub = w.s(0).events.listen(events.add);
      w.central.setAvailable('dev0', available: false);
      await w.run(const Duration(milliseconds: 100));
      // A drag to 0 made out of range must not turn the light off later.
      w.s(0).setBrightness(0);
      expect(w.s(0).status.state!.sleeping, isTrue);
      await w.run(const Duration(seconds: 61));
      // Back to the light's real value, said once.
      expect(w.s(0).status.offlineBrightness, isNull);
      expect(w.s(0).status.state!.sleeping, isFalse);
      expect(w.s(0).status.state!.scene.brightness, real);
      expect(events.whereType<EbOfflineChangesExpired>(), hasLength(1));
      // When the light returns, nothing is sent: it stays on.
      w.central.setAvailable('dev0', available: true);
      await w.run(const Duration(seconds: 40));
      expect(w.s(0).status.phase, LinkPhase.ready);
      expect(model.sleeping, isFalse);
      expect(model.scene.brightness, real);
      expect(events.whereType<EbOfflineChangesExpired>(), hasLength(1));
      await sub.cancel();
      await w.dispose();
    },
  );

  test(
    'released at 0 while not connected: shown off, turned off when back',
    () async {
      final _World w = _World();
      w.manager.want('f0', WantReason.screen);
      await w.run(const Duration(seconds: 1));
      final model = w.central.fixtures.first.model;
      expect(model.sleeping, isFalse);
      w.central.setAvailable('dev0', available: false);
      await w.run(const Duration(milliseconds: 100));
      w.s(0).setBrightness(0);
      expect(w.s(0).status.state!.sleeping, isTrue);
      w.central.setAvailable('dev0', available: true);
      await w.run(const Duration(seconds: 6));
      expect(w.s(0).status.phase, LinkPhase.ready);
      expect(model.sleeping, isTrue);
      // The level it wakes to is its old one, stored after the fade.
      expect(model.scene.brightness, 255);
      expect(w.s(0).status.state!.sleeping, isTrue);
      await w.dispose();
    },
  );

  test(
    'link lost while waiting to store the wake level: stored when back',
    () async {
      final _World w = _World();
      w.manager.want('f0', WantReason.screen);
      await w.run(const Duration(seconds: 1));
      final model = w.central.fixtures.first.model;
      w.s(0).setBrightness(150);
      await w.run(const Duration(seconds: 1));
      w.s(0).setBrightness(0);
      // SLEEP answered, the fade wait not over yet: the link drops.
      await w.run(const Duration(milliseconds: 200));
      expect(model.sleeping, isTrue);
      expect(model.scene.brightness, 0);
      w.central.setAvailable('dev0', available: false);
      await w.run(const Duration(seconds: 2));
      w.central.setAvailable('dev0', available: true);
      await w.run(const Duration(seconds: 6));
      expect(w.s(0).status.phase, LinkPhase.ready);
      expect(model.sleeping, isTrue);
      expect(model.scene.brightness, 150);
      await w.dispose();
    },
  );

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
    'the reconnect scan stops as the app goes to background, not later',
    () async {
      final _World w = _World();
      w.central.setAvailable('dev0', available: false);
      w.manager.want('f0', WantReason.screen);
      await w.run(const Duration(seconds: 1));
      expect(w.discovery.strongestNeed, ScanNeed.reconnect);
      await w.manager.onBackground();
      expect(w.discovery.strongestNeed, isNull);
      await w.manager.onForeground();
      expect(w.discovery.strongestNeed, ScanNeed.reconnect);
      await w.dispose();
    },
  );

  test('a paused discovery keeps its leases and resumes the scan', () async {
    final _World w = _World();
    final ScanLease lease = w.discovery.acquire(ScanNeed.addFlow);
    await w.run(const Duration(milliseconds: 100));
    expect(w.discovery.isScanning, isTrue);
    w.discovery.paused = true;
    expect(w.discovery.isScanning, isFalse);
    expect(w.discovery.strongestNeed, ScanNeed.addFlow);
    w.discovery.paused = false;
    expect(w.discovery.isScanning, isTrue);
    lease.release();
    await w.dispose();
  });

  test('a light that fails while advertising keeps its backoff', () async {
    final ManualScheduler clock = ManualScheduler();
    final SimCentral sim = SimCentral(
      scheduler: clock,
      fixtures: <SimFixture>[SimFixture.electroBright(id: 'dev0')],
    );
    final _RefusingCentral central = _RefusingCentral(sim)..refuse = true;
    final Discovery discovery = Discovery(
      central: central,
      scheduler: clock,
      isAndroid: false,
    );
    final ConnectionManager manager = ConnectionManager(
      central: central,
      discovery: discovery,
      scheduler: clock,
      policy: const ConnectionPolicy(isAndroid: false),
    );
    manager.register(
      Fixture(
        id: 'f0',
        deviceId: 'dev0',
        name: 'Light 0',
        layout: ChannelLayout.rgbw,
        driver: DriverKind.electroBright,
        addedAt: DateTime(2026),
      ),
    );
    manager.want('f0', WantReason.screen);
    Future<void> run(Duration d) async {
      const Duration step = Duration(milliseconds: 10);
      for (Duration t = Duration.zero; t < d; t += step) {
        await _pump(5);
        clock.advance(step);
      }
      await _pump();
    }

    // Adverts every 150 ms; the backoff (0.5, 1, 2, 4, 8 s with jitter)
    // allows about six attempts in 20 s, not one per advert.
    await run(const Duration(seconds: 20));
    expect(central.connects, inInclusiveRange(4, 7));
    expect(manager.session('f0')!.status.phase, LinkPhase.unavailable);
    // Once it takes connections it connects on its next scheduled retry.
    central.refuse = false;
    await run(const Duration(seconds: 20));
    expect(manager.session('f0')!.status.phase, LinkPhase.ready);
    await manager.dispose();
    await discovery.dispose();
    sim.dispose();
  });

  test('a light that comes back reconnects on its first advert', () async {
    final _World w = _World();
    w.central.setAvailable('dev0', available: false);
    w.manager.want('f0', WantReason.favourite);
    // Long gone: its backoff is at its longest.
    await w.run(const Duration(seconds: 120));
    expect(w.s(0).status.phase, LinkPhase.unavailable);
    w.central.setAvailable('dev0', available: true);
    await w.run(const Duration(seconds: 1));
    expect(w.s(0).status.phase, LinkPhase.ready);
    await w.dispose();
  });

  test('iOS: favourites waiting for absent lights never block a light the '
      'user opens', () async {
    final _World w = _World(lights: 3);
    w.central.setAvailable('dev0', available: false);
    w.central.setAvailable('dev1', available: false);
    w.manager.want('f0', WantReason.favourite);
    w.manager.want('f1', WantReason.favourite);
    await w.run(const Duration(seconds: 3));
    expect(w.s(0).status.phase, LinkPhase.connecting);
    expect(w.s(1).status.phase, LinkPhase.connecting);
    w.manager.want('f2', WantReason.screen);
    await w.run(const Duration(seconds: 1));
    expect(w.s(2).status.phase, LinkPhase.ready);
    // The waiting favourites connect as soon as their lights appear.
    w.central.setAvailable('dev0', available: true);
    await w.run(const Duration(seconds: 1));
    expect(w.s(0).status.phase, LinkPhase.ready);
    await w.dispose();
  });

  test(
    'iOS: in the background a waiting connect is abandoned, so it never '
    'takes a light that appears; back in the foreground it connects',
    () async {
      final _World w = _World();
      w.central.setAvailable('dev0', available: false);
      w.manager.want('f0', WantReason.favourite);
      await w.run(const Duration(seconds: 3));
      expect(w.s(0).status.phase, LinkPhase.connecting);
      await w.manager.onBackground();
      await w.run(const Duration(seconds: 21));
      final int links = w.radio.links;
      w.central.setAvailable('dev0', available: true);
      await w.run(const Duration(seconds: 5));
      expect(w.radio.links, links, reason: 'no link, not even a brief one');
      await w.manager.onForeground();
      await w.run(const Duration(seconds: 2));
      expect(w.s(0).status.phase, LinkPhase.ready);
      await w.dispose();
    },
  );

  test('iOS: a waiting connect nobody wants is abandoned', () async {
    final _World w = _World();
    w.central.setAvailable('dev0', available: false);
    final Want want = w.manager.want('f0', WantReason.favourite);
    await w.run(const Duration(seconds: 3));
    expect(w.s(0).status.phase, LinkPhase.connecting);
    want.release();
    await w.run(const Duration(milliseconds: 100));
    expect(w.s(0).status.phase, LinkPhase.idle);
    final int connects = w.central.connects;
    w.central.setAvailable('dev0', available: true);
    await w.run(const Duration(seconds: 3));
    expect(w.central.fixtures.single.connected, isFalse);
    expect(w.central.connects, connects);
    await w.dispose();
  });

  test('a device is fresh from its first advert until 10 s without one; a '
      'scan restart forgets what was heard before', () async {
    final _World w = _World(lights: 2);
    final List<String> stale = <String>[];
    final StreamSubscription<String> sub = w.discovery.stale.listen(stale.add);
    ScanLease lease = w.discovery.acquire(ScanNeed.addFlow);
    expect(w.discovery.isFresh('dev1'), isFalse);
    await w.run(const Duration(milliseconds: 300));
    expect(w.discovery.isFresh('dev1'), isTrue, reason: 'first advert');
    // Advertising: it never drops out (no flicker).
    for (int i = 0; i < 300; i++) {
      await w.run(const Duration(milliseconds: 100));
      expect(w.discovery.isFresh('dev1'), isTrue);
    }
    expect(stale, isEmpty);

    // Switched off: listed for the full 10 s after its last advert, then not.
    w.central.setAvailable('dev1', available: false);
    await w.run(const Duration(milliseconds: 9500));
    expect(w.discovery.isFresh('dev1'), isTrue);
    await w.run(const Duration(milliseconds: 800));
    expect(w.discovery.isFresh('dev1'), isFalse);
    expect(stale, <String>['dev1']);
    expect(w.discovery.seen('dev1'), isNotNull, reason: 'still remembered');
    // Back on: fresh again with its first advert.
    w.central.setAvailable('dev1', available: true);
    await w.run(const Duration(milliseconds: 300));
    expect(w.discovery.isFresh('dev1'), isTrue);

    // The scan restarts: nothing from before until heard again.
    lease.release();
    expect(w.discovery.isFresh('dev0'), isFalse);
    expect(w.discovery.isFresh('dev1'), isFalse);
    lease = w.discovery.acquire(ScanNeed.addFlow);
    expect(w.discovery.isFresh('dev1'), isFalse);
    await w.run(const Duration(milliseconds: 300));
    expect(w.discovery.isFresh('dev1'), isTrue);

    lease.release();
    await sub.cancel();
    await w.dispose();
  });

  test('an unsaved device unseen for 2 minutes of scanning is forgotten; '
      'a saved light never is', () async {
    final _World w = _World(lights: 2);
    // dev1 isn't saved: only dev0 is registered.
    await w.manager.unregister('f1');
    w.discovery.keep = w.manager.manages;
    final List<String> forgotten = <String>[];
    final StreamSubscription<String> sub = w.discovery.forgotten.listen(
      forgotten.add,
    );
    final ScanLease lease = w.discovery.acquire(ScanNeed.addFlow);
    await w.run(const Duration(seconds: 1));
    expect(w.discovery.seen('dev0'), isNotNull);
    expect(w.discovery.seen('dev1'), isNotNull);

    // Both go away. Time without a scan doesn't count.
    w.central.setAvailable('dev0', available: false);
    w.central.setAvailable('dev1', available: false);
    lease.release();
    await w.run(const Duration(minutes: 5));
    final ScanLease again = w.discovery.acquire(ScanNeed.addFlow);
    await w.run(const Duration(seconds: 90));
    expect(w.discovery.seen('dev1'), isNotNull);
    // Two minutes of scanning without a sight of it: forgotten.
    await w.run(const Duration(seconds: 45));
    expect(w.discovery.seen('dev1'), isNull);
    expect(forgotten, <String>['dev1']);
    expect(w.discovery.seen('dev0'), isNotNull, reason: 'saved: kept');

    again.release();
    await sub.cancel();
    await w.dispose();
  });

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
