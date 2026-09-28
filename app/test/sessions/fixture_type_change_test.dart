import 'dart:async';

import 'package:electrobright/core/model/channel_layout.dart';
import 'package:electrobright/core/model/fixture.dart';
import 'package:electrobright/core/protocol/eb/eb_fixture_catalog.dart';
import 'package:electrobright/core/store/json_store.dart';
import 'package:electrobright/core/util/scheduler.dart';
import 'package:electrobright/drivers/electrobright/eb_types.dart';
import 'package:electrobright/sessions/connection_manager.dart';
import 'package:electrobright/sessions/discovery.dart';
import 'package:electrobright/sessions/fixture_registry.dart';
import 'package:electrobright/sessions/fixture_session.dart';
import 'package:electrobright/sessions/group_session.dart';
import 'package:electrobright/sim/eb_device_model.dart';
import 'package:electrobright/sim/sim_central.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _pump([int n = 30]) async {
  for (int i = 0; i < n; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// Firmware 3.7.0 is one image for every fixture type. A light that comes
/// back as another type (SET_TYPE, same device id) is re-identified, and a
/// light without a type (setup-needed mode) is kept but only ever sent the
/// commands that mode accepts.
void main() {
  late ManualScheduler clock;
  late SimCentral central;
  late Discovery discovery;
  late ConnectionManager manager;
  late JsonStore store;
  late FixtureRegistry registry;
  late GroupSessions groups;

  Future<void> run(Duration d) async {
    const Duration step = Duration(milliseconds: 10);
    for (Duration t = Duration.zero; t < d; t += step) {
      await _pump(5);
      clock.advance(step);
    }
    await _pump();
  }

  setUp(() {
    clock = ManualScheduler();
    central = SimCentral(
      scheduler: clock,
      fixtures: <SimFixture>[
        SimFixture.electroBright(id: 'dev1'), // RGBW
        SimFixture.electroBright(id: 'dev2', fixture: EbFixtureCatalog.cct),
        SimFixture.setupNeeded(id: 'dev3'),
      ],
    );
    discovery = Discovery(central: central, scheduler: clock, isAndroid: false);
    manager = ConnectionManager(
      central: central,
      discovery: discovery,
      scheduler: clock,
      policy: ConnectionPolicy(isAndroid: false),
    );
    store = JsonStore.memory();
    registry = FixtureRegistry(store: store, connections: manager);
    groups = GroupSessions(
      registry: registry,
      connections: manager,
      store: store,
      scheduler: clock,
    );
  });

  tearDown(() async {
    groups.dispose();
    await registry.dispose();
    await manager.dispose();
    await discovery.dispose();
    central.dispose();
  });

  Fixture light(String id, String device, ChannelLayout layout) => Fixture(
    id: id,
    deviceId: device,
    name: id,
    layout: layout,
    driver: DriverKind.electroBright,
    addedAt: DateTime(2026),
  );

  EbDeviceModel twin(String device) =>
      central.fixtures.firstWhere((SimFixture f) => f.id == device).model;

  List<String> members(GroupSession g) =>
      g.status.members.map((GroupMember m) => m.id).toList();

  test('a light that restarts as another type is re-identified', () async {
    registry
      ..add(light('f1', 'dev1', ChannelLayout.rgbw))
      ..add(light('f2', 'dev2', ChannelLayout.cct));
    final Want w = manager.want('f1', WantReason.screen);
    await run(const Duration(seconds: 5));
    final FixtureSession s = manager.session('f1')!;
    expect(s.status.isReady, isTrue);
    expect(registry.byId('f1')!.capabilities.supportsTypeChange, isTrue);
    expect(registry.byId('f1')!.capabilities.supportsProbe, isTrue);
    // App-side preset names of this light (and another light's).
    store.write('presetMeta', <String, Object?>{
      'f1': <String, Object?>{'3': <String, Object?>{'name': 'Movie'}},
      'f2': <String, Object?>{'1': <String, Object?>{'name': 'Read'}},
    });
    expect(members(groups.colour), <String>['f1']);
    expect(members(groups.white), <String>['f2']);
    final List<LayoutChange> changes = <LayoutChange>[];
    final StreamSubscription<LayoutChange> sub = registry.layoutChanges
        .listen(changes.add);

    expect(
      (await _settled(s.session!.probe(3, on: true), run)).outcome,
      EbOutcome.ok,
    );
    final Future<EbResult> set = s.session!.setType(ChannelLayout.cct);
    await run(const Duration(seconds: 1));
    expect((await set).outcome, EbOutcome.ok);
    expect(twin('dev1').restarts, 1);
    // The link dropped with the restart; the wanted light reconnects.
    await run(const Duration(seconds: 8));
    expect(s.status.isReady, isTrue);

    final Fixture f = registry.byId('f1')!;
    expect(f.layout, ChannelLayout.cct);
    expect(f.identity!.model, 'EB-C3-CCT-V1');
    expect(f.capabilities.layout, ChannelLayout.cct);
    expect(changes.single.before.layout, ChannelLayout.rgbw);
    expect(changes.single.after.layout, ChannelLayout.cct);
    final Map<String, Object?> meta =
        store.read('presetMeta')! as Map<String, Object?>;
    expect(meta.containsKey('f1'), isFalse);
    expect(meta.containsKey('f2'), isTrue);
    expect(twin('dev1').presetSlots, isEmpty);
    // A tunable-white light now: it moved from the colour to the white group.
    await _pump();
    expect(members(groups.colour), isEmpty);
    expect(members(groups.white), <String>['f1', 'f2']);

    // Same type again: nothing restarts.
    expect(
      (await _settled(s.session!.setType(ChannelLayout.cct), run)).outcome,
      EbOutcome.ok,
    );
    expect(twin('dev1').restarts, 1);

    w.release();
    await sub.cancel();
  });

  test('a setup-needed light is kept and only sent the setup commands',
      () async {
    // Seen advertising first: the handshake starts with CAPS.
    final ScanLease scan = discovery.acquire(ScanNeed.addFlow);
    await run(const Duration(seconds: 1));
    scan.release();
    registry.add(light('f3', 'dev3', ChannelLayout.rgbw));
    final Want w = manager.want('f3', WantReason.screen);
    await run(const Duration(seconds: 5));

    final FixtureSession s = manager.session('f3')!;
    expect(s.status.phase, LinkPhase.incompatible);
    expect(s.status.incompatibility, EbIncompatibility.setupNeeded);
    expect(registry.byId('f3'), isNotNull);
    expect(registry.byId('f3')!.layout, ChannelLayout.rgbw); // untouched
    Map<String, Object> stats() =>
        twin('dev3').state()['stats']! as Map<String, Object>;
    // CAPS and VERSION only: no command the light rejects.
    expect(stats()['err'], 0);
    expect(stats()['unk'], 0);
    expect(stats()['rx'], 2);

    // Retried by the user: still nothing outside the allowed set.
    manager.retry('f3');
    await run(const Duration(seconds: 5));
    expect(s.status.incompatibility, EbIncompatibility.setupNeeded);
    expect(stats()['err'], 0);
    expect(stats()['rx'], 4); // CAPS + VERSION again
    w.release();
  });

  test('a retry never adds a rejected command', () async {
    registry.add(light('f3', 'dev3', ChannelLayout.rgbw));
    final Want w = manager.want('f3', WantReason.screen);
    await run(const Duration(seconds: 5));
    final FixtureSession s = manager.session('f3')!;
    expect(s.status.incompatibility, EbIncompatibility.setupNeeded);
    Map<String, Object> stats() =>
        twin('dev3').state()['stats']! as Map<String, Object>;
    final Object? errors = stats()['err'];
    manager.retry('f3');
    await run(const Duration(seconds: 5));
    expect(s.status.incompatibility, EbIncompatibility.setupNeeded);
    expect(stats()['err'], errors); // CAPS first from now on
    w.release();
  });
}

Future<EbResult> _settled(
  Future<EbResult> r,
  Future<void> Function(Duration) run,
) async {
  await run(const Duration(seconds: 1));
  return r;
}
