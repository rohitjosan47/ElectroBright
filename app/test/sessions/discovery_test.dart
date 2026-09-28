import 'dart:async';
import 'dart:typed_data';

import 'package:electrobright/core/ble/ble_central.dart';
import 'package:electrobright/core/ble/ble_link.dart';
import 'package:electrobright/core/protocol/eb/eb_constants.dart';
import 'package:electrobright/core/util/scheduler.dart';
import 'package:electrobright/sessions/discovery.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _pump([int n = 10]) async {
  for (int i = 0; i < n; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

final class _Scan {
  _Scan(this.services, this.intensity);
  final List<String> services;
  final ScanIntensity intensity;
  // Closed by the scan subscription's cancel.
  // ignore: close_sinks
  late final StreamController<Advertisement> controller;
  bool cancelled = false;
}

/// A radio the test drives by hand: it records every scan and delivers
/// adverts only when told to.
final class _FakeCentral implements BleCentral {
  final StreamController<BleAdapterState> _adapter =
      StreamController<BleAdapterState>.broadcast();
  BleAdapterState _state = BleAdapterState.ready;
  final List<_Scan> scans = <_Scan>[];

  _Scan? get active {
    final Iterable<_Scan> live = scans.where((_Scan s) => !s.cancelled);
    return live.isEmpty ? null : live.last;
  }

  void setAdapter(BleAdapterState s) {
    _state = s;
    _adapter.add(s);
  }

  void advert(
    String id, {
    String name = 'ElectroBright_C3_RGBW',
    int rssi = -60,
    List<String> services = const <String>[Eb.serviceUuid],
    Uint8List? data,
    bool connectable = true,
  }) {
    active!.controller.add(
      Advertisement(
        id: id,
        name: name,
        rssi: rssi,
        serviceUuids: services,
        manufacturerData: data ?? Uint8List(0),
        connectable: connectable,
      ),
    );
  }

  @override
  BleAdapterState get currentAdapterState => _state;

  @override
  Stream<BleAdapterState> get adapterState {
    StreamSubscription<BleAdapterState>? inner;
    // Closed by its listener's cancel.
    // ignore: close_sinks
    late final StreamController<BleAdapterState> out;
    out = StreamController<BleAdapterState>(
      onListen: () {
        out.add(_state);
        inner = _adapter.stream.listen(out.add);
      },
      onCancel: () => inner?.cancel(),
    );
    return out.stream;
  }

  @override
  Stream<Advertisement> scan({
    List<String> services = const <String>[],
    ScanIntensity intensity = ScanIntensity.balanced,
  }) {
    final _Scan s = _Scan(services, intensity);
    s.controller = StreamController<Advertisement>(
      onCancel: () {
        s.cancelled = true;
        unawaited(s.controller.close());
      },
    );
    scans.add(s);
    return s.controller.stream;
  }

  @override
  Future<BleLink> connect(
    String deviceId, {
    required Map<String, List<String>> services,
    Duration? timeout,
    Future<void>? cancel,
  }) => throw UnimplementedError();

  @override
  Future<void> clearCache(String deviceId) async {}

  Future<void> dispose() => _adapter.close();
}

final class _World {
  _World({bool android = false, List<String> extra = const <String>[]}) {
    discovery = Discovery(
      central: central,
      scheduler: clock,
      isAndroid: android,
      extraServices: extra,
    );
  }

  final ManualScheduler clock = ManualScheduler();
  final _FakeCentral central = _FakeCentral();
  late final Discovery discovery;

  Future<void> run(Duration d) async {
    const Duration step = Duration(milliseconds: 500);
    Duration left = d;
    while (left > Duration.zero) {
      final Duration s = left < step ? left : step;
      await _pump(3);
      clock.advance(s);
      left -= s;
    }
    await _pump();
  }

  Future<void> dispose() async {
    await discovery.dispose();
    await central.dispose();
  }
}

void main() {
  group('scan needs', () {
    test('no lease, no scan; the strongest lease decides filter and '
        'intensity', () async {
      final _World w = _World();
      await _pump();
      expect(w.discovery.isScanning, isFalse);
      expect(w.discovery.strongestNeed, isNull);
      expect(w.discovery.scanning, isNull);

      final ScanLease badge = w.discovery.acquire(ScanNeed.badge);
      await _pump();
      expect(w.discovery.strongestNeed, ScanNeed.badge);
      expect(w.discovery.scanning!.services, <String>[Eb.serviceUuid]);
      expect(w.discovery.scanning!.intensity, ScanIntensity.lowPower);
      expect(w.central.active!.intensity, ScanIntensity.lowPower);

      final ScanLease reconnect = w.discovery.acquire(ScanNeed.reconnect);
      expect(w.discovery.scanning!.intensity, ScanIntensity.balanced);

      final ScanLease panel = w.discovery.acquire(ScanNeed.panel);
      expect(w.discovery.scanning!.services, <String>[Eb.serviceUuid]);
      expect(w.discovery.scanning!.intensity, ScanIntensity.lowLatency);

      final ScanLease add = w.discovery.acquire(ScanNeed.addFlow);
      expect(w.discovery.strongestNeed, ScanNeed.addFlow);
      expect(w.discovery.scanning!.services, isEmpty, reason: 'unfiltered');
      expect(w.discovery.scanning!.intensity, ScanIntensity.lowLatency);
      expect(w.central.active!.services, isEmpty);
      expect(w.discovery.scanStarts, 4);

      add.release();
      expect(w.discovery.strongestNeed, ScanNeed.panel);
      expect(w.discovery.scanning!.services, <String>[Eb.serviceUuid]);
      panel.release();
      reconnect.release();
      expect(w.discovery.scanning!.intensity, ScanIntensity.lowPower);
      badge.release();
      expect(w.discovery.isScanning, isFalse);
      expect(w.discovery.strongestNeed, isNull);
      await _pump();
      expect(w.central.scans.every((_Scan s) => s.cancelled), isTrue);
      expect(w.discovery.scanStarts, 7);
      await w.dispose();
    });

    test('a lease for the same config does not restart the scan; release is '
        'idempotent and only the last lease stops it', () async {
      final _World w = _World();
      await _pump();
      final ScanLease a = w.discovery.acquire(ScanNeed.panel);
      final ScanLease b = w.discovery.acquire(ScanNeed.panel);
      expect(w.discovery.scanStarts, 1);
      a
        ..release()
        ..release();
      expect(w.discovery.isScanning, isTrue);
      expect(w.discovery.strongestNeed, ScanNeed.panel);
      // A weaker lease under a stronger one changes nothing.
      final ScanLease c = w.discovery.acquire(ScanNeed.presence);
      expect(w.discovery.scanStarts, 1);
      b.release();
      c.release();
      expect(w.discovery.isScanning, isFalse);
      await w.dispose();
    });

    test('extra services join the filter', () async {
      final _World w = _World(extra: <String>['abcd']);
      await _pump();
      w.discovery.acquire(ScanNeed.reconnect);
      expect(w.discovery.scanning!.services, <String>[Eb.serviceUuid, 'abcd']);
      await w.dispose();
    });

    test('iOS presence is duty-cycled: 8 s on, 22 s off', () async {
      final _World w = _World();
      await _pump();
      w.discovery.acquire(ScanNeed.presence);
      expect(w.discovery.isScanning, isTrue);
      await w.run(const Duration(milliseconds: 7900));
      expect(w.discovery.isScanning, isTrue);
      await w.run(const Duration(milliseconds: 100));
      expect(w.discovery.isScanning, isFalse);
      // Another presence lease during the off phase keeps it off.
      w.discovery.acquire(ScanNeed.presence);
      expect(w.discovery.isScanning, isFalse);
      await w.run(const Duration(milliseconds: 21900));
      expect(w.discovery.isScanning, isFalse);
      await w.run(const Duration(milliseconds: 100));
      expect(w.discovery.isScanning, isTrue);
      expect(w.discovery.scanStarts, 2);
      // A stronger need during an off phase scans at once.
      await w.run(const Duration(seconds: 8));
      expect(w.discovery.isScanning, isFalse);
      final ScanLease badge = w.discovery.acquire(ScanNeed.badge);
      expect(w.discovery.isScanning, isTrue);
      await w.run(const Duration(minutes: 1));
      expect(w.discovery.isScanning, isTrue, reason: 'badge never cycles');
      badge.release();
      expect(w.discovery.isScanning, isTrue, reason: 'presence restarts');
      await w.dispose();
    });

    test('Android presence scans continuously at low power', () async {
      final _World w = _World(android: true);
      await _pump();
      w.discovery.acquire(ScanNeed.presence);
      await w.run(const Duration(minutes: 1));
      expect(w.discovery.isScanning, isTrue);
      expect(w.discovery.scanning!.intensity, ScanIntensity.lowPower);
      expect(w.discovery.scanStarts, 1);
      await w.dispose();
    });

    test('Android: at most 4 scan starts per 30 s; a further change waits '
        'for the window while the current scan keeps running', () async {
      final _World w = _World(android: true);
      await _pump();
      w.discovery.acquire(ScanNeed.panel); // 1
      ScanLease add = w.discovery.acquire(ScanNeed.addFlow); // 2
      add.release(); // 3
      await w.run(const Duration(seconds: 5));
      add = w.discovery.acquire(ScanNeed.addFlow); // 4
      expect(w.discovery.scanStarts, 4);
      add.release(); // out of budget
      expect(w.discovery.scanStarts, 4);
      expect(w.discovery.isScanning, isTrue);
      expect(w.discovery.scanning!.services, isEmpty, reason: 'still addFlow');
      await w.run(const Duration(milliseconds: 24900));
      expect(w.discovery.scanStarts, 4);
      await w.run(const Duration(milliseconds: 100));
      expect(w.discovery.scanStarts, 5);
      expect(w.discovery.scanning!.services, <String>[Eb.serviceUuid]);
      await w.dispose();
    });

    test('iOS has no start budget', () async {
      final _World w = _World();
      await _pump();
      w.discovery.acquire(ScanNeed.panel);
      for (int i = 0; i < 6; i++) {
        w.discovery.acquire(ScanNeed.addFlow).release();
      }
      expect(w.discovery.scanStarts, 13);
      await w.dispose();
    });
  });

  group('adapter and pause', () {
    test('no scan before the adapter reports ready', () async {
      final _World w = _World();
      w.discovery.acquire(ScanNeed.panel);
      expect(w.discovery.isScanning, isFalse, reason: 'state still unknown');
      await _pump();
      expect(w.discovery.isScanning, isTrue);
      await w.dispose();
    });

    for (final BleAdapterState off in <BleAdapterState>[
      BleAdapterState.poweredOff,
      BleAdapterState.unauthorized,
      BleAdapterState.unsupported,
      BleAdapterState.locationServicesDisabled,
    ]) {
      test('adapter ${off.name}: the scan stops, leases are kept; ready '
          'again restarts it', () async {
        final _World w = _World();
        await _pump();
        w.discovery.acquire(ScanNeed.reconnect);
        final _Scan first = w.central.active!;
        w.central.setAdapter(off);
        await _pump();
        expect(w.discovery.isScanning, isFalse);
        expect(first.cancelled, isTrue);
        expect(w.discovery.strongestNeed, ScanNeed.reconnect);
        // Lease changes while off start nothing.
        w.discovery.acquire(ScanNeed.addFlow);
        expect(w.discovery.isScanning, isFalse);
        w.central.setAdapter(BleAdapterState.ready);
        await _pump();
        expect(w.discovery.isScanning, isTrue);
        expect(w.discovery.scanning!.services, isEmpty);
        expect(w.discovery.scanStarts, 2);
        await w.dispose();
      });
    }

    test('adapter off makes every fresh device stale; what was seen is '
        'kept', () async {
      final _World w = _World();
      await _pump();
      final List<String> stale = <String>[];
      w.discovery.stale.listen(stale.add);
      w.discovery.acquire(ScanNeed.panel);
      w.central.advert('a');
      await _pump();
      expect(w.discovery.isFresh('a'), isTrue);
      w.central.setAdapter(BleAdapterState.poweredOff);
      await _pump();
      expect(w.discovery.isFresh('a'), isFalse);
      expect(stale, <String>['a']);
      expect(w.discovery.seen('a'), isNotNull);
      await w.dispose();
    });

    test('paused stops the scan and keeps leases; unpaused resumes', () async {
      final _World w = _World();
      await _pump();
      w.discovery.acquire(ScanNeed.panel);
      w.discovery.paused = true;
      expect(w.discovery.paused, isTrue);
      expect(w.discovery.isScanning, isFalse);
      w.discovery.paused = true; // no-op
      w.discovery.acquire(ScanNeed.addFlow);
      expect(w.discovery.isScanning, isFalse);
      w.discovery.paused = false;
      expect(w.discovery.isScanning, isTrue);
      expect(w.discovery.strongestNeed, ScanNeed.addFlow);
      expect(w.discovery.scanning!.services, isEmpty);
      await w.dispose();
    });

    test('a scan error stops the scan; the next change restarts it', () async {
      final _World w = _World();
      await _pump();
      w.discovery.acquire(ScanNeed.panel);
      w.central.active!.controller.addError(StateError('scan failed'));
      await _pump();
      expect(w.discovery.isScanning, isFalse);
      w.discovery.acquire(ScanNeed.panel);
      expect(w.discovery.isScanning, isTrue);
      expect(w.discovery.scanStarts, 2);
      await w.dispose();
    });
  });

  group('adverts', () {
    test('adverts are merged per device and published on updates', () async {
      final _World w = _World();
      await _pump();
      final List<SeenDevice> updates = <SeenDevice>[];
      w.discovery.updates.listen(updates.add);
      w.discovery.acquire(ScanNeed.addFlow);
      w.central.advert(
        'a',
        rssi: -50,
        data: Uint8List.fromList(<int>[1, 2]),
        services: <String>['x'],
      );
      await w.run(const Duration(seconds: 1));
      w.central.advert(
        'a',
        name: '',
        rssi: -80,
        services: <String>['y'],
        connectable: false,
      );
      await _pump();
      expect(updates, hasLength(2));
      final SeenDevice d = w.discovery.seen('a')!;
      expect(updates.last, same(d));
      expect(d.name, 'ElectroBright_C3_RGBW', reason: 'empty name keeps old');
      expect(d.rssi, (-50 * 0.7 + -80 * 0.3).round());
      expect(d.serviceUuids, <String>{'x', 'y'});
      expect(d.manufacturerData, <int>[1, 2], reason: 'empty keeps old');
      expect(d.connectable, isFalse, reason: 'the latest advert wins');
      expect(d.lastSeen, const Duration(seconds: 1));
      expect(w.discovery.devices.map((SeenDevice x) => x.id), <String>['a']);
      expect(w.discovery.seen('b'), isNull);
      await w.dispose();
    });

    test('device class and signal bars', () {
      SeenDevice dev(String name, {int rssi = -60, Set<String>? svc}) =>
          SeenDevice(
            id: name,
            name: name,
            rssi: rssi,
            serviceUuids: svc ?? <String>{},
            manufacturerData: Uint8List(0),
            lastSeen: Duration.zero,
            connectable: true,
          );
      expect(
        dev(Eb.legacyName, svc: <String>{Eb.serviceUuid}).deviceClass,
        DeviceClass.legacyElectroBright,
      );
      expect(
        dev('ElectroBright_C3_RGB').deviceClass,
        DeviceClass.electroBright,
      );
      expect(
        dev('', svc: <String>{Eb.serviceUuid}).deviceClass,
        DeviceClass.electroBright,
      );
      expect(dev('Headphones').deviceClass, DeviceClass.other);
      expect(
        <int>[
          -60,
          -61,
          -70,
          -71,
          -80,
          -81,
          -90,
          -91,
        ].map((int r) => dev('x', rssi: r).signalBars),
        <int>[4, 3, 3, 2, 2, 1, 1, 0],
      );
    });

    test('seenRecently is inclusive of its window; unknown ids are never '
        'recent', () async {
      final _World w = _World();
      await _pump();
      w.discovery.acquire(ScanNeed.panel);
      w.central.advert('a');
      await _pump();
      expect(w.discovery.seenRecently('a', const Duration(seconds: 2)), isTrue);
      await w.run(const Duration(seconds: 2));
      expect(w.discovery.seenRecently('a', const Duration(seconds: 2)), isTrue);
      await w.run(const Duration(milliseconds: 1));
      expect(
        w.discovery.seenRecently('a', const Duration(seconds: 2)),
        isFalse,
      );
      expect(w.discovery.seenRecently('a', const Duration(minutes: 1)), isTrue);
      expect(w.discovery.seenRecently('zz', const Duration(days: 1)), isFalse);
      await w.dispose();
    });

    test('a device is fresh from its first advert until nearbyFresh of '
        'silence', () async {
      final _World w = _World();
      await _pump();
      final List<String> stale = <String>[];
      w.discovery.stale.listen(stale.add);
      w.discovery.acquire(ScanNeed.panel);
      w.central.advert('a');
      await w.run(const Duration(seconds: 4));
      w.central.advert('b');
      await w.run(const Duration(seconds: 5));
      w.central.advert('a'); // t = 9 s
      await w.run(const Duration(seconds: 5)); // t = 14 s
      expect(w.discovery.isFresh('a'), isTrue);
      expect(w.discovery.isFresh('b'), isFalse, reason: 'silent since 4 s');
      expect(stale, <String>['b']);
      await w.run(const Duration(milliseconds: 4900));
      expect(w.discovery.isFresh('a'), isTrue);
      await w.run(const Duration(milliseconds: 100));
      expect(w.discovery.isFresh('a'), isFalse);
      expect(stale, <String>['b', 'a']);
      await w.dispose();
    });

    test('a scan restart drops freshness', () async {
      final _World w = _World();
      await _pump();
      final List<String> stale = <String>[];
      w.discovery.stale.listen(stale.add);
      w.discovery.acquire(ScanNeed.panel);
      w.central.advert('a');
      await _pump();
      final ScanLease add = w.discovery.acquire(ScanNeed.addFlow);
      await _pump();
      expect(w.discovery.isFresh('a'), isFalse);
      expect(stale, <String>['a']);
      w.central.advert('a');
      await _pump();
      expect(w.discovery.isFresh('a'), isTrue);
      add.release();
      await _pump();
      expect(w.discovery.isFresh('a'), isFalse);
      await w.dispose();
    });
  });

  group('forgetting', () {
    test('during an unfiltered scan an unsaved device silent for over 2 min '
        'is forgotten; kept and heard devices stay', () async {
      final _World w = _World();
      await _pump();
      final List<String> forgotten = <String>[];
      w.discovery.forgotten.listen(forgotten.add);
      w.discovery.keep = (String id) => id == 'saved';
      w.discovery.acquire(ScanNeed.addFlow);
      w.central
        ..advert('gone')
        ..advert('saved')
        ..advert('here');
      for (int i = 0; i < 25; i++) {
        await w.run(const Duration(seconds: 5));
        w.central.advert('here');
      }
      // t = 125 s: silent for 125 s, but checks run every 10 s.
      expect(forgotten, isEmpty);
      await w.run(const Duration(seconds: 5));
      expect(forgotten, <String>['gone']);
      expect(w.discovery.seen('gone'), isNull);
      expect(w.discovery.seen('saved'), isNotNull);
      expect(w.discovery.seen('here'), isNotNull);
      await w.dispose();
    });

    test('only time spent scanning unfiltered counts', () async {
      final _World w = _World();
      await _pump();
      final List<String> forgotten = <String>[];
      w.discovery.forgotten.listen(forgotten.add);
      final ScanLease panel = w.discovery.acquire(ScanNeed.panel);
      w.central.advert('a');
      await w.run(const Duration(minutes: 5));
      expect(forgotten, isEmpty, reason: 'a filtered scan forgets nothing');
      final ScanLease add = w.discovery.acquire(ScanNeed.addFlow);
      await w.run(const Duration(seconds: 110));
      expect(forgotten, isEmpty, reason: 'unfiltered for under 2 min');
      // Stopping resets the clock: 2 more minutes of unfiltered scanning.
      add.release();
      panel.release();
      await w.run(const Duration(minutes: 5));
      w.discovery.acquire(ScanNeed.addFlow);
      await w.run(const Duration(seconds: 110));
      expect(forgotten, isEmpty);
      await w.run(const Duration(seconds: 10));
      expect(forgotten, <String>['a']);
      await w.dispose();
    });
  });

  test('dispose stops the scan and closes the streams', () async {
    final _World w = _World();
    await _pump();
    bool updatesDone = false;
    bool staleDone = false;
    bool forgottenDone = false;
    w.discovery.updates.listen((_) {}, onDone: () => updatesDone = true);
    w.discovery.stale.listen((_) {}, onDone: () => staleDone = true);
    w.discovery.forgotten.listen((_) {}, onDone: () => forgottenDone = true);
    w.discovery.acquire(ScanNeed.presence);
    final _Scan scan = w.central.active!;
    await w.dispose();
    await _pump();
    expect(scan.cancelled, isTrue);
    expect(updatesDone && staleDone && forgottenDone, isTrue);
    // Nothing fires later (duty-cycle timer halted).
    w.clock.advance(const Duration(minutes: 1));
    expect(w.central.scans, hasLength(1));
  });
}
