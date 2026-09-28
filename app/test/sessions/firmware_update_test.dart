import 'dart:async';
import 'dart:typed_data';

import 'package:electrobright/core/ble/ble_central.dart';
import 'package:electrobright/core/ble/ble_link.dart';
import 'package:electrobright/core/firmware/firmware_bundle.dart';
import 'package:electrobright/core/model/channel_layout.dart';
import 'package:electrobright/core/model/fixture.dart';
import 'package:electrobright/core/protocol/eb/eb_ota.dart';
import 'package:electrobright/core/store/json_store.dart';
import 'package:electrobright/core/util/scheduler.dart';
import 'package:electrobright/sessions/connection_manager.dart';
import 'package:electrobright/sessions/discovery.dart';
import 'package:electrobright/sessions/firmware_update.dart';
import 'package:electrobright/sessions/fixture_registry.dart';
import 'package:electrobright/sessions/fixture_session.dart';
import 'package:electrobright/sessions/group_session.dart';
import 'package:electrobright/sim/eb_device_model.dart';
import 'package:electrobright/sim/ota_twin.dart';
import 'package:electrobright/sim/sim_central.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/firmware_images.dart';

Future<void> _pump([int n = 20]) async {
  for (int i = 0; i < n; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// The simulated radio with knobs on the update service's writes: drop the
/// link after a number of DATA writes, corrupt one, swallow DATA for a while,
/// or hide the update service.
final class _Radio implements BleCentral {
  _Radio(this.sim, this.clock);
  final SimCentral sim;
  final ManualScheduler clock;

  /// Drops the link at this DATA write (1-based; then the light is back
  /// after [dropFor]).
  int? dropAtData;
  Duration dropFor = const Duration(seconds: 1);

  /// Flips a payload byte of this DATA write (1-based).
  int? corruptData;

  /// DATA writes are lost until this app time.
  Duration? swallowUntil;
  bool hideUpdateService = false;

  /// END_OK never reaches the app (lost to the light's restart).
  bool dropEndOk = false;

  int dataWrites = 0;
  int dataBytes = 0;
  final List<Uint8List> control = <Uint8List>[];
  final List<Uint8List> notes = <Uint8List>[];

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
  bool offers(String serviceUuid) =>
      !(_radio.hideUpdateService && serviceUuid == EbOta.serviceUuid) &&
      _inner.offers(serviceUuid);
  @override
  Future<LinkLossReason> get closed => _inner.closed;
  @override
  Stream<Uint8List> subscribe(GattRef ref) {
    final Stream<Uint8List> s = _inner.subscribe(ref);
    if (ref.characteristic != EbOta.controlUuid) return s;
    return s
        .where((Uint8List n) => !(_radio.dropEndOk && n[0] == EbOta.endOk))
        .map((Uint8List n) {
          _radio.notes.add(n);
          return n;
        });
  }

  @override
  Future<void> write(
    GattRef ref,
    Uint8List value, {
    required bool withResponse,
  }) async {
    if (ref.characteristic == EbOta.controlUuid) _radio.control.add(value);
    if (ref.characteristic == EbOta.dataUuid) {
      final int n = ++_radio.dataWrites;
      _radio.dataBytes += value.length - EbOta.dataHeader;
      if (n == _radio.dropAtData) {
        _radio.sim.setAvailable(deviceId, available: false);
        _radio.clock.after(_radio.dropFor, () {
          _radio.sim.setAvailable(deviceId, available: true);
        });
        throw const LinkClosedException(LinkLossReason.lost);
      }
      final Duration? until = _radio.swallowUntil;
      if (until != null && _radio.clock.now < until) return;
      if (n == _radio.corruptData) {
        value = Uint8List.fromList(value);
        value[value.length - 1] ^= 0xFF;
      }
    }
    return _inner.write(ref, value, withResponse: withResponse);
  }

  @override
  Future<void> disconnect() => _inner.disconnect();
}

/// The platform's background tasks, recorded.
final class _Tasks implements BackgroundTasks {
  final List<String> log = <String>[];
  int _ids = 0;

  @override
  Future<int> begin(String name) async {
    log.add('begin $name');
    return ++_ids;
  }

  @override
  Future<void> end(int id) async => log.add('end $id');
}

/// The update engine against the simulated lights' update service (the
/// firmware twin, kept equal to the real core by the OTA differential test).
void main() {
  late ManualScheduler clock;
  late SimCentral sim;
  late _Radio radio;
  late Discovery discovery;
  late ConnectionManager manager;
  late JsonStore store;
  late FixtureRegistry registry;
  late GroupSessions groups;
  late FirmwareUpdates updates;
  late List<UpdateProgress> seen;
  late _Tasks tasks;

  /// When each progress was seen (app time).
  late List<(Duration, UpdateProgress)> timeline;

  Future<void> run(Duration d) async {
    const Duration step = Duration(milliseconds: 10);
    for (Duration t = Duration.zero; t < d; t += step) {
      await _pump(3);
      clock.advance(step);
    }
    await _pump();
  }

  /// Runs until [f] completes (at most [limit] of app time).
  Future<T> until<T>(
    Future<T> f, {
    Duration limit = const Duration(seconds: 120),
  }) async {
    bool done = false;
    late T value;
    unawaited(
      f.then((T v) {
        done = true;
        value = v;
      }),
    );
    const Duration step = Duration(milliseconds: 10);
    for (Duration t = Duration.zero; t < limit && !done; t += step) {
      await _pump(3);
      clock.advance(step);
    }
    await _pump();
    expect(done, isTrue, reason: 'did not finish within $limit');
    return value;
  }

  void setUpWith(List<SimFixture> lights) {
    clock = ManualScheduler();
    sim = SimCentral(scheduler: clock, fixtures: lights);
    radio = _Radio(sim, clock);
    tasks = _Tasks();
    discovery = Discovery(central: radio, scheduler: clock, isAndroid: false);
    manager = ConnectionManager(
      central: radio,
      discovery: discovery,
      scheduler: clock,
      policy: ConnectionPolicy(isAndroid: false),
      backgroundTasks: tasks,
    );
    store = JsonStore.memory();
    registry = FixtureRegistry(store: store, connections: manager);
    groups = GroupSessions(
      registry: registry,
      connections: manager,
      store: store,
      scheduler: clock,
    );
    updates = FirmwareUpdates(connections: manager, scheduler: clock);
    seen = <UpdateProgress>[];
    timeline = <(Duration, UpdateProgress)>[];
    updates.changes.listen((UpdateProgress p) {
      seen.add(p);
      timeline.add((clock.now, p));
    });
  }

  /// When [stage] was first reached.
  Duration at(UpdateStage stage) => timeline
      .firstWhere(((Duration, UpdateProgress) e) => e.$2.stage == stage)
      .$1;

  int begins() =>
      radio.control.where((Uint8List c) => c[0] == EbOta.begin).length;

  tearDown(() async {
    await updates.dispose();
    groups.dispose();
    await registry.dispose();
    await manager.dispose();
    await discovery.dispose();
    sim.dispose();
  });

  Fixture light(
    String id,
    String device, [
    ChannelLayout l = ChannelLayout.rgbw,
  ]) => Fixture(
    id: id,
    deviceId: device,
    name: id,
    layout: l,
    driver: DriverKind.electroBright,
    addedAt: DateTime(2026),
  );

  EbDeviceModel twin(String device) =>
      sim.fixtures.firstWhere((SimFixture f) => f.id == device).model;

  /// One saved light 'f1' on 'dev1' (running [version]), connected.
  Future<FixtureSession> connected({String version = '3.8.0'}) async {
    setUpWith(<SimFixture>[
      SimFixture.electroBright(id: 'dev1', version: version),
    ]);
    registry.add(light('f1', 'dev1'));
    final Want w = manager.want('f1', WantReason.screen);
    addTearDown(w.release);
    await run(const Duration(seconds: 3));
    final FixtureSession s = manager.session('f1')!;
    expect(s.status.isReady, isTrue);
    return s;
  }

  Future<UpdateProgress> update(
    FirmwareImage image, {
    bool reinstall = false,
  }) => until(
    updates.start(
      'f1',
      version: image.version,
      image: () async => image,
      reinstall: reinstall,
    ),
  );

  List<UpdateStage> stages() => <UpdateStage>[
    for (int i = 0; i < seen.length; i++)
      if (i == 0 || seen[i - 1].stage != seen[i].stage) seen[i].stage,
  ];

  test('a full transfer installs the new firmware and confirms it', () async {
    final FixtureSession s = await connected();
    final FirmwareImage image = testImage(size: 50000);
    final UpdateProgress done = await update(image);
    expect(done.stage, UpdateStage.done, reason: '$done');
    expect(done.from, const FirmwareVersion(3, 8, 0));
    expect(done.to, const FirmwareVersion(3, 9, 0));
    expect(stages(), <UpdateStage>[
      UpdateStage.preparing,
      UpdateStage.sending,
      UpdateStage.installing,
      UpdateStage.restarting,
      UpdateStage.checking,
      UpdateStage.done,
    ]);
    // Every byte once; progress up to the whole image.
    expect(radio.dataBytes, image.size);
    expect(done.stats, isNotNull);
    expect(done.stats!.bytes, image.size);
    expect(done.stats!.windowResends, 0);
    expect(done.stats!.resumes, 0);
    expect(done.stats!.bytesPerSecond, greaterThan(0));
    expect(
      seen.map((UpdateProgress p) => p.sent).reduce((a, b) => a > b ? a : b),
      image.size,
    );
    // Same device, restarted once, now on 3.9.0 (and the app knows it).
    final EbDeviceModel m = twin('dev1');
    expect(m.restarts, 1);
    expect(m.runningVersion, '3.9.0');
    expect(m.otaFlash.running, 1);
    expect(m.selfChecking, isFalse);
    expect(s.status.isReady, isTrue);
    expect(s.status.updating, isFalse);
    expect(s.status.view!.firmware!.version.version, '3.9.0');
    expect(registry.byId('f1')!.identity!.firmwareVersion, '3.9.0');
    // The light is driven normally again.
    expect((await s.setPower(on: false)).isSuccess, isTrue);
  });

  test('a dropped link mid-window resumes where the light got to', () async {
    await connected();
    final FirmwareImage image = testImage(size: 60000);
    // 70 writes of 178 bytes: in the middle of the second window.
    radio.dropAtData = 70;
    final UpdateProgress done = await update(image);
    expect(done.stage, UpdateStage.done, reason: '$done');
    expect(seen.any((UpdateProgress p) => p.reconnecting), isTrue);
    // The second BEGIN resumed: nothing was sent twice but the window cut
    // short by the drop.
    final List<Uint8List> begins = radio.control
        .where((Uint8List c) => c[0] == EbOta.begin)
        .toList();
    expect(begins.length, 2);
    final List<int> starts = <int>[
      for (final Uint8List n in radio.notes)
        if (n[0] == EbOta.beginOk)
          ByteData.sublistView(n).getUint32(1, Endian.little),
    ];
    expect(starts.first, 0);
    expect(starts.last, greaterThan(EbOta.window));
    expect(starts.last % EbOta.window, isNot(0));
    expect(radio.dataBytes, lessThan(image.size + EbOta.window));
    expect(twin('dev1').runningVersion, '3.9.0');
    // The cut window went again once, on the second link.
    expect(done.stats!.windowResends, 1);
    expect(done.stats!.resumes, 1);
    expect(done.stats!.bytes, image.size);
  });

  test('a damaged transfer is refused (hash mismatch)', () async {
    final FixtureSession s = await connected();
    radio.corruptData = 30;
    final UpdateProgress r = await update(testImage());
    expect(r.stage, UpdateStage.failed);
    expect(r.problem, UpdateProblem.damaged);
    final EbDeviceModel m = twin('dev1');
    expect(m.restarts, 0);
    expect(m.runningVersion, '3.8.0');
    expect(m.ota.active, isFalse);
    expect(s.status.updating, isFalse);
    expect(s.status.isReady, isTrue);
  });

  test('an image without the ElectroBright identity is refused', () async {
    await connected();
    final UpdateProgress r = await update(testImage(product: 'SomethingElse'));
    expect(r.problem, UpdateProblem.notAccepted);
    expect(twin('dev1').restarts, 0);
    expect(twin('dev1').otaFlash.running, 0);

    seen.clear();
    final UpdateProgress r2 = await update(testImage(identity: false));
    expect(r2.problem, UpdateProblem.notAccepted);
  });

  test('a downgrade is never sent', () async {
    await connected(version: '3.9.0');
    final UpdateProgress r = await update(testImage(version: '3.8.5'));
    expect(r.stage, UpdateStage.failed);
    expect(r.problem, UpdateProblem.downgrade);
    expect(radio.control, isEmpty);
    expect(radio.dataWrites, 0);
    // The same version needs the reinstall flag.
    final UpdateProgress same = await update(testImage());
    expect(same.problem, UpdateProblem.sameVersion);
    expect(radio.control, isEmpty);
  });

  test('reinstall sends the same version again', () async {
    await connected(version: '3.9.0');
    final UpdateProgress r = await update(testImage(), reinstall: true);
    expect(r.stage, UpdateStage.done, reason: '$r');
    final Uint8List begin = radio.control.firstWhere(
      (Uint8List c) => c[0] == EbOta.begin,
    );
    expect(begin[43] & EbOta.flagReinstall, EbOta.flagReinstall);
    final EbDeviceModel m = twin('dev1');
    expect(m.restarts, 1);
    expect(m.otaFlash.running, 1);
    expect(m.runningVersion, '3.9.0');
  });

  test('a transfer the light timed out on resumes', () async {
    await connected();
    // DATA is lost for 20 s: the light stops the transfer (TIMEOUT) and the
    // app resumes it once writes get through again.
    radio.swallowUntil = clock.now + const Duration(seconds: 20);
    final UpdateProgress r = await update(testImage(size: 30000));
    expect(r.stage, UpdateStage.done, reason: '$r');
    expect(
      radio.notes.any(
        (Uint8List n) => n[0] == EbOta.error && n[1] == EbOtaError.timeout.code,
      ),
      isTrue,
    );
    expect(
      radio.control.where((Uint8List c) => c[0] == EbOta.begin).length,
      greaterThan(1),
    );
  });

  test(
    'a transfer that never gets through stops with a clear reason',
    () async {
      final FixtureSession s = await connected();
      radio.swallowUntil = const Duration(days: 1);
      final UpdateProgress r = await update(testImage(size: 30000));
      expect(r.stage, UpdateStage.failed);
      expect(r.problem, UpdateProblem.stalled);
      expect(s.status.updating, isFalse);
      expect(twin('dev1').restarts, 0);
    },
  );

  test('cancel aborts the transfer; the light keeps its firmware', () async {
    final FixtureSession s = await connected();
    final FirmwareImage image = testImage(size: 80000);
    final Future<UpdateProgress> f = updates.start(
      'f1',
      version: image.version,
      image: () async => image,
    );
    // Swallowed writes keep it in the sending stage long enough to cancel.
    radio.swallowUntil = clock.now + const Duration(seconds: 2);
    await run(const Duration(milliseconds: 500));
    expect(updates.progressOf('f1')!.stage, UpdateStage.sending);
    expect(updates.progressOf('f1')!.cancellable, isTrue);
    expect(s.status.updating, isTrue);
    updates.cancel('f1');
    final UpdateProgress r = await until(f);
    expect(r.stage, UpdateStage.cancelled);
    expect(radio.control.last[0], EbOta.abort);
    expect(radio.notes.last[0], EbOta.aborted);
    final EbDeviceModel m = twin('dev1');
    expect(m.ota.active, isFalse);
    expect(m.ota.canResume, isFalse);
    expect(m.restarts, 0);
    expect(s.status.updating, isFalse);
    expect(s.session!.lanesPaused, isFalse);
    expect((await s.setPower(on: false)).isSuccess, isTrue);
    await run(const Duration(milliseconds: 300));
    expect(m.sleeping, isTrue);
  });

  test('a rollback is reported', () async {
    final FixtureSession s = await connected();
    twin('dev1').failSelfCheck = true;
    final UpdateProgress r = await update(testImage());
    expect(r.stage, UpdateStage.rolledBack, reason: '$r');
    expect(r.problem, isNull);
    final EbDeviceModel m = twin('dev1');
    // Restarted into the update, then back.
    expect(m.restarts, 2);
    expect(m.runningVersion, '3.8.0');
    expect(m.otaFlash.rolledBack, isTrue);
    expect(s.status.view!.firmware!.version.version, '3.8.0');
    expect(s.status.updating, isFalse);
  });

  for (final (int mark, String name) in <(int, String)>[
    (1, 'fails its self-check'),
    (2, 'freezes before its self-check'),
  ]) {
    test('a rollback test image that $name goes back on its own; DIAG says '
        'so', () async {
      final FixtureSession s = await connected(version: '3.8.1');
      final UpdateProgress r = await update(
        testImage(version: '3.8.9999', rollbackTest: mark),
      );
      expect(r.stage, UpdateStage.rolledBack, reason: '$r');
      expect(r.slotBefore, 0);
      expect(r.slotAfter, 0);
      expect(r.rolledBackFlag, isTrue);
      final EbDeviceModel m = twin('dev1');
      expect(m.runningVersion, '3.8.1');
      expect(m.otaFlash.running, 0);
      expect(m.otaFlash.rolledBack, isTrue);
      expect(s.status.view!.firmware!.version.version, '3.8.1');
      expect(s.status.isReady, isTrue);
    });
  }

  test('no update service: unsupported, nothing sent', () async {
    await connected();
    radio.hideUpdateService = true;
    // Reconnect so the link is looked at again.
    await manager.reconnect('f1');
    await run(const Duration(seconds: 3));
    final UpdateProgress r = await update(testImage());
    expect(r.problem, UpdateProblem.unsupported);
    expect(radio.control, isEmpty);
  });

  test(
    'offers only older firmware of lights with the update service',
    () async {
      final FixtureSession s = await connected();
      expect(
        FirmwareUpdates.offers(s.status, const FirmwareVersion(3, 9, 0)),
        isTrue,
      );
      expect(
        FirmwareUpdates.offers(s.status, const FirmwareVersion(3, 8, 0)),
        isFalse,
      );
      expect(
        FirmwareUpdates.offers(s.status, const FirmwareVersion(3, 7, 9)),
        isFalse,
      );
      expect(FirmwareUpdates.offers(s.status, null), isFalse);
    },
  );

  test('one light at a time; while it updates its lanes pause and groups '
      'skip it', () async {
    setUpWith(<SimFixture>[
      SimFixture.electroBright(id: 'dev1'),
      SimFixture.electroBright(id: 'dev2'),
    ]);
    registry
      ..add(light('f1', 'dev1'))
      ..add(light('f2', 'dev2'));
    final GroupSession colour = groups.colour;
    colour.activate();
    await run(const Duration(seconds: 3));
    final FixtureSession s1 = manager.session('f1')!;
    final FixtureSession s2 = manager.session('f2')!;
    expect(s1.status.isReady && s2.status.isReady, isTrue);

    final FirmwareImage image = testImage(size: 80000);
    radio.swallowUntil = clock.now + const Duration(seconds: 4);
    final Future<UpdateProgress> f = updates.start(
      'f1',
      version: image.version,
      image: () async => image,
    );
    await run(const Duration(milliseconds: 500));
    expect(s1.status.updating, isTrue);
    expect(s1.status.isReady, isFalse);
    expect(s1.status.isConnected, isTrue);
    expect(s1.session!.lanesPaused, isTrue);

    // One at a time.
    final UpdateProgress other = await until(
      updates.start('f2', version: image.version, image: () async => image),
    );
    expect(other.problem, UpdateProblem.anotherUpdate);
    expect(updates.activeId, 'f1');

    // The light's own intents are refused, not kept for later.
    final EbDeviceModel m1 = twin('dev1'), m2 = twin('dev2');
    final int rx = (m1.state()['stats']! as Map<String, Object>)['rx']! as int;
    expect(await s1.setPower(on: false), FixtureSession.updatingResult);
    expect(await s1.setMode(3), FixtureSession.updatingResult);
    // The group drives only the other light.
    final GroupResult g = await colour.setPower(on: false);
    await run(const Duration(milliseconds: 500));
    expect(g, isNotNull);
    expect(m2.sleeping, isTrue);
    expect(m1.sleeping, isFalse);
    expect(
      (m1.state()['stats']! as Map<String, Object>)['rx']! as int,
      rx,
      reason: 'no text command reached the updating light',
    );

    final UpdateProgress r = await until(f);
    expect(r.stage, UpdateStage.done, reason: '$r');
    expect(s1.status.isReady, isTrue);
    // Back in the group: it follows again.
    await until(colour.setPower(on: true));
    await run(const Duration(milliseconds: 500));
    expect(m1.sleeping, isFalse);
    expect(m2.sleeping, isFalse);
  });

  // ---- R3: END_OK lost ---------------------------------------------------------

  test('END_OK lost to the restart: back on the new firmware is a success, '
      'straight to confirmation (no BEGIN again)', () async {
    final FixtureSession s = await connected();
    radio.dropEndOk = true;
    final UpdateProgress r = await update(testImage(size: 30000));
    expect(r.stage, UpdateStage.done, reason: '$r');
    expect(begins(), 1);
    expect(radio.notes.any((Uint8List n) => n[0] == EbOta.endOk), isFalse);
    expect(stages(), <UpdateStage>[
      UpdateStage.preparing,
      UpdateStage.sending,
      UpdateStage.installing,
      UpdateStage.checking,
      UpdateStage.done,
    ]);
    final EbDeviceModel m = twin('dev1');
    expect(m.restarts, 1);
    expect(m.runningVersion, '3.9.0');
    expect(m.otaFlash.running, 1);
    expect(s.status.isReady, isTrue);
    expect(s.status.updating, isFalse);
  });

  test('END_OK lost on a reinstall: DIAG tells the new slot, no second '
      'transfer', () async {
    await connected(version: '3.9.0');
    radio.dropEndOk = true;
    final UpdateProgress r = await update(testImage(), reinstall: true);
    expect(r.stage, UpdateStage.done, reason: '$r');
    expect(begins(), 1);
    final EbDeviceModel m = twin('dev1');
    expect(m.restarts, 1);
    expect(m.otaFlash.running, 1);
  });

  // ---- R11: pending-verify -------------------------------------------------------

  /// Keeps the new firmware unconfirmed (DIAG pv=1) until [until], then
  /// confirms it.
  void holdPending(EbDeviceModel m, Duration until) {
    void tick() {
      if (m.runningVersion != '3.9.0') {
        clock.after(const Duration(milliseconds: 20), tick);
        return;
      }
      if (clock.now >= until) {
        m.otaFlash.confirm();
        return;
      }
      if (!m.selfChecking) {
        m.otaFlash.state[m.otaFlash.running] = OtaSlotState.pendingVerify;
      }
      clock.after(const Duration(milliseconds: 20), tick);
    }

    tick();
  }

  test('confirmation ends once pending-verify clears, not after a fixed '
      'window', () async {
    await connected();
    final UpdateProgress r = await update(testImage(size: 20000));
    expect(r.stage, UpdateStage.done, reason: '$r');
    // The twin confirms itself right after booting: well within 18 s.
    expect(
      at(UpdateStage.done) - at(UpdateStage.installing),
      lessThan(const Duration(seconds: 8)),
    );
  });

  test('confirmation waits as long as pending-verify is set', () async {
    await connected();
    final Duration from = clock.now;
    holdPending(twin('dev1'), from + const Duration(seconds: 40));
    final UpdateProgress r = await update(testImage(size: 20000));
    expect(r.stage, UpdateStage.done, reason: '$r');
    expect(
      at(UpdateStage.done) - from,
      greaterThan(const Duration(seconds: 40)),
    );
    expect(at(UpdateStage.done) - from, lessThan(const Duration(seconds: 43)));
    expect(twin('dev1').runningVersion, '3.9.0');
  });

  test('a light that never confirms stops with a clear reason', () async {
    final FixtureSession s = await connected();
    holdPending(twin('dev1'), const Duration(days: 1));
    final UpdateProgress r = await until(
      updates.start(
        'f1',
        version: const FirmwareVersion(3, 9, 0),
        image: () async => testImage(size: 20000),
      ),
      limit: const Duration(seconds: 200),
    );
    expect(r.stage, UpdateStage.failed);
    expect(r.problem, UpdateProblem.unconfirmed);
    expect(
      at(UpdateStage.failed) - at(UpdateStage.checking),
      greaterThanOrEqualTo(const UpdateTiming().verify),
    );
    expect(s.status.updating, isFalse);
  });

  // ---- R4: background ----------------------------------------------------------

  test(
    'in the background an update keeps its link and the background task; '
    'other lights go after the grace; the task ends with the update',
    () async {
      setUpWith(<SimFixture>[
        SimFixture.electroBright(id: 'dev1', version: '3.8.0'),
        SimFixture.electroBright(id: 'dev2', version: '3.8.0'),
      ]);
      registry
        ..add(light('f1', 'dev1'))
        ..add(light('f2', 'dev2'));
      final Want w1 = manager.want('f1', WantReason.screen);
      final Want w2 = manager.want('f2', WantReason.screen);
      addTearDown(w1.release);
      addTearDown(w2.release);
      await run(const Duration(seconds: 3));
      final FixtureSession s1 = manager.session('f1')!;
      final FixtureSession s2 = manager.session('f2')!;

      final FirmwareImage image = testImage(size: 40000);
      // Stalled DATA keeps the transfer going well past the grace period.
      radio.swallowUntil = clock.now + const Duration(seconds: 22);
      final Future<UpdateProgress> f = updates.start(
        'f1',
        version: image.version,
        image: () async => image,
      );
      await run(const Duration(milliseconds: 500));
      expect(updates.progressOf('f1')!.stage, UpdateStage.sending);

      await manager.onBackground();
      await run(const Duration(seconds: 21));
      expect(s2.status.isConnected, isFalse);
      expect(s1.status.isConnected, isTrue);
      expect(s1.status.updating, isTrue);
      expect(tasks.log, <String>['begin eb-release']);
      expect(updates.progressOf('f1')!.running, isTrue);

      final UpdateProgress r = await until(f);
      expect(r.stage, UpdateStage.done, reason: '$r');
      expect(r.paused, isFalse);
      expect(twin('dev1').runningVersion, '3.9.0');
      await run(const Duration(seconds: 1));
      // The update is over: its light goes too, and the task ends.
      expect(s1.status.isConnected, isFalse);
      expect(tasks.log, <String>['begin eb-release', 'end 1']);

      await manager.onForeground();
      await run(const Duration(seconds: 3));
      expect(s1.status.isReady && s2.status.isReady, isTrue);
    },
  );

  test('suspended in the background anyway: the update pauses, says so, and '
      'resumes where it stopped on return', () async {
    final FixtureSession s = await connected();
    final FirmwareImage image = testImage(size: 200000);
    final Future<UpdateProgress> f = updates.start(
      'f1',
      version: image.version,
      image: () async => image,
    );
    await run(const Duration(milliseconds: 400));
    expect(updates.progressOf('f1')!.stage, UpdateStage.sending);
    await manager.onBackground();
    await run(const Duration(milliseconds: 600));
    expect(updates.progressOf('f1')!.stage, UpdateStage.sending);
    expect(updates.progressOf('f1')!.sent, greaterThan(0));

    // The OS ends the background task: every link goes.
    await manager.onBackgroundExpiring();
    await run(const Duration(seconds: 1));
    expect(manager.suspended, isTrue);
    expect(s.status.isConnected, isFalse);
    UpdateProgress p = updates.progressOf('f1')!;
    expect(p.running, isTrue);
    expect(p.paused, isTrue);
    expect(tasks.log.last, startsWith('end'));

    // However long it stays suspended, nothing times out or reconnects.
    await run(const Duration(minutes: 3));
    p = updates.progressOf('f1')!;
    expect(p.running, isTrue, reason: '$p');
    expect(p.paused, isTrue);
    expect(s.status.isConnected, isFalse);
    expect(begins(), 1);

    await manager.onForeground();
    expect(manager.suspended, isFalse);
    final UpdateProgress r = await until(f);
    expect(r.stage, UpdateStage.done, reason: '$r');
    expect(r.paused, isFalse);
    // Resumed from where the light got to, not from the start.
    final List<int> starts = <int>[
      for (final Uint8List n in radio.notes)
        if (n[0] == EbOta.beginOk)
          ByteData.sublistView(n).getUint32(1, Endian.little),
    ];
    expect(starts.length, 2);
    expect(starts.last, greaterThan(0));
    expect(radio.dataBytes, lessThan(image.size + EbOta.window));
    // The paused note went once it moved again.
    final int resumedAt = seen.lastIndexWhere((UpdateProgress p) => p.paused);
    expect(seen[resumedAt + 1].sent, greaterThan(seen[resumedAt].sent));
    expect(twin('dev1').runningVersion, '3.9.0');
  });

  // ---- R9: OTA capability ------------------------------------------------------

  test('OTA=0: no offer; the update says a one-time USB install is needed, '
      'never "too big"', () async {
    final FixtureSession s = await connected(version: '3.8.2');
    final EbDeviceModel m = twin('dev1');
    m.otaFlash.capacity = 0;
    m.reboot();
    // Reconnect so the light is asked again.
    await manager.reconnect('f1');
    await run(const Duration(seconds: 5));
    expect(s.status.isReady, isTrue);
    expect(m.capsReply, contains('OTA=0'));
    expect(s.status.view!.firmware!.needsUsbInstall, isTrue);
    expect(s.status.view!.firmware!.wirelessUpdates, isFalse);
    expect(
      FirmwareUpdates.offers(s.status, const FirmwareVersion(3, 9, 0)),
      isFalse,
    );
    final UpdateProgress r = await update(testImage());
    expect(r.stage, UpdateStage.failed);
    expect(r.problem, UpdateProblem.needsUsbInstall);
    expect(radio.control, isEmpty);
    expect(radio.dataWrites, 0);
  });
}
