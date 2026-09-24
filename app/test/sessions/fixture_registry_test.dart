import 'dart:async';
import 'dart:io';

import 'package:electrobright/core/model/channel_color.dart';
import 'package:electrobright/core/model/channel_layout.dart';
import 'package:electrobright/core/model/fixture.dart';
import 'package:electrobright/core/protocol/eb/eb_fixture_catalog.dart';
import 'package:electrobright/core/store/json_store.dart';
import 'package:electrobright/core/util/scheduler.dart';
import 'package:electrobright/sessions/connection_manager.dart';
import 'package:electrobright/sessions/discovery.dart';
import 'package:electrobright/sessions/fixture_registry.dart';
import 'package:electrobright/sessions/fixture_session.dart';
import 'package:electrobright/sim/sim_central.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _pump([int n = 30]) async {
  for (int i = 0; i < n; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late Directory dir;
  final ManualScheduler clock = ManualScheduler();
  late SimCentral central;
  late Discovery discovery;
  late ConnectionManager manager;

  Future<void> run(Duration d) async {
    const Duration step = Duration(milliseconds: 10);
    for (Duration t = Duration.zero; t < d; t += step) {
      await _pump(5);
      clock.advance(step);
    }
    await _pump();
  }

  ConnectionManager newManager() => ConnectionManager(
    central: central,
    discovery: discovery,
    scheduler: clock,
    policy: ConnectionPolicy(isAndroid: false),
  );

  setUp(() {
    dir = Directory.systemTemp.createTempSync('eb-registry');
    central = SimCentral(
      scheduler: clock,
      fixtures: <SimFixture>[
        SimFixture.electroBright(id: 'dev1', fixture: EbFixtureCatalog.cct),
      ],
    );
    discovery = Discovery(central: central, scheduler: clock, isAndroid: false);
    manager = newManager();
  });

  tearDown(() async {
    await manager.dispose();
    await discovery.dispose();
    central.dispose();
    dir.deleteSync(recursive: true);
  });

  Fixture guess() => Fixture(
    id: 'f1',
    deviceId: 'dev1',
    name: 'Kitchen',
    layout: ChannelLayout.rgbw,
    driver: DriverKind.electroBright,
    addedAt: DateTime(2026),
    identity: FixtureIdentity.assumed(ChannelLayout.rgbw),
  );

  test('learns the type and capabilities; a reflash is reported', () async {
    final JsonStore store = await JsonStore.open(dir);
    final FixtureRegistry reg = FixtureRegistry(
      store: store,
      connections: manager,
    );
    final List<LayoutChange> changes = <LayoutChange>[];
    final StreamSubscription<LayoutChange> sub = reg.layoutChanges.listen(
      changes.add,
    );
    reg.add(guess());
    final Want w = manager.want('f1', WantReason.screen);
    await run(const Duration(seconds: 5));

    Fixture f = reg.byId('f1')!;
    expect(f.layout, ChannelLayout.cct);
    expect(f.identity!.assumed, isFalse);
    expect(f.identity!.model, 'EB-C3-CCT-V1');
    expect(f.identity!.firmwareVersion, '3.5.0');
    expect(f.identity!.caps, contains('LAYOUT=CCT'));
    expect(changes, isEmpty); // an assumed type being corrected is not news

    // The board is reflashed as a single-white light.
    w.release();
    await run(const Duration(seconds: 70));
    central.fixtures[0] = SimFixture.electroBright(
      id: 'dev1',
      fixture: EbFixtureCatalog.w,
    );
    final Want w2 = manager.want('f1', WantReason.screen);
    await run(const Duration(seconds: 5));
    f = reg.byId('f1')!;
    expect(f.layout, ChannelLayout.w);
    expect(f.capabilities.supportsMode(10), isFalse);
    expect(changes.single.before.layout, ChannelLayout.cct);
    expect(changes.single.after.layout, ChannelLayout.w);

    w2.release();
    await sub.cancel();
    await reg.dispose();
    await store.close();
  });

  test('last-known state survives a restart; forget drops the light', () async {
    JsonStore store = await JsonStore.open(dir);
    final FixtureRegistry reg = FixtureRegistry(
      store: store,
      connections: manager,
    );
    reg.add(guess());
    final Want w = manager.want('f1', WantReason.screen);
    await run(const Duration(seconds: 5));
    manager
        .session('f1')!
        .setColor(ChannelColor(ChannelLayout.cct, <int>[12, 240]));
    await run(const Duration(seconds: 1));
    w.release();
    await run(const Duration(seconds: 70)); // idle grace: disconnects
    expect(manager.session('f1')!.status.phase, isNot(LinkPhase.ready));
    await reg.saveAll();
    await reg.dispose();
    await manager.dispose();

    // "Restart": a new store, manager and registry from disk.
    store = await JsonStore.open(dir);
    manager = newManager();
    final FixtureRegistry again = FixtureRegistry(
      store: store,
      connections: manager,
    );
    expect(again.byId('f1')!.layout, ChannelLayout.cct);
    final FixtureStatus st = manager.session('f1')!.status;
    expect(st.phase, isNot(LinkPhase.ready));
    expect(st.state!.scene.color.values, <int>[12, 240]); // shown at once

    await again.forget('f1');
    expect(again.fixtures, isEmpty);
    expect(manager.session('f1'), isNull);
    expect(
      (store.read('lastKnown') as Map<String, Object?>?)?.containsKey('f1') ??
          false,
      isFalse,
    );
    await again.dispose();
  });
}
