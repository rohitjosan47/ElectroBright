import 'dart:async';
import 'dart:io';

import 'package:electrobright/core/color/colour_engine.dart';
import 'package:electrobright/core/color/led_white_points.dart';
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
import 'package:electrobright/sim/eb_device_model.dart';
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
    expect(f.identity!.firmwareVersion, EbDeviceModel.firmwareVersion);
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

  test('a repeated status is not emitted; last-known is saved once', () async {
    final JsonStore store = await JsonStore.open(dir);
    final FixtureRegistry reg = FixtureRegistry(
      store: store,
      connections: manager,
    );
    reg.add(guess());
    final Want w = manager.want('f1', WantReason.screen);
    await run(const Duration(seconds: 5));
    w.release();
    await run(const Duration(seconds: 70)); // idle grace: disconnects
    final FixtureSession session = manager.session('f1')!;
    expect(session.status.phase, isNot(LinkPhase.ready));
    expect(session.status.lastKnown, isNotNull);

    final List<FixtureStatus> emits = <FixtureStatus>[];
    final StreamSubscription<FixtureStatus> sub = session.statuses.listen(
      emits.add,
    );
    final int writes = store.writes;
    // Connection churn while it's away: each change of phase is news, a
    // repeat is not; the last-known state is unchanged, so never rewritten.
    session.setPhase(LinkPhase.waiting);
    session.setPhase(LinkPhase.waiting);
    session.setPhase(LinkPhase.connecting);
    session.setPhase(LinkPhase.connecting);
    session.setPhase(LinkPhase.unavailable, attempt: 3);
    session.setPhase(LinkPhase.unavailable, attempt: 3);
    await _pump();
    expect(
      <LinkPhase>[for (final FixtureStatus e in emits) e.phase],
      <LinkPhase>[
        LinkPhase.waiting,
        LinkPhase.connecting,
        LinkPhase.unavailable,
      ],
    );
    expect(store.writes, writes);

    await sub.cancel();
    await reg.dispose();
    await store.close();
  });

  test('white points come from the catalog, replacing saved ones', () async {
    const LedWhitePoints stale = LedWhitePoints(cwK: 5000, wwK: 3000);
    final LedWhitePoints product = EbFixtureCatalog.cct.whitePoints;
    expect(product, isNot(stale));
    final JsonStore store = await JsonStore.open(dir);
    final FixtureRegistry reg = FixtureRegistry(
      store: store,
      connections: manager,
    );
    final List<List<Fixture>> emitted = <List<Fixture>>[];
    final StreamSubscription<List<Fixture>> sub = reg.changes.listen(
      emitted.add,
    );
    reg.add(guess().copyWith(whitePoints: stale));
    Want w = manager.want('f1', WantReason.screen);
    await run(const Duration(seconds: 5));

    Fixture f = reg.byId('f1')!;
    expect(f.layout, ChannelLayout.cct);
    expect(f.whitePoints, product);
    // The Kelvin range the colour screen offers is the product's.
    final ({double min, double max}) range = ColourEngine(f.whitePoints)
        .whiteRange(ChannelLayout.cct);
    expect(range.min, product.wwK.toDouble());
    expect(range.max, product.cwK.toDouble());
    // The live session and the fixtures stream (the UI) have it too.
    expect(manager.session('f1')!.fixture.whitePoints, product);
    expect(emitted.last.single.whitePoints, product);

    // Values edited by hand (or saved by an older app) on an otherwise
    // unchanged light: corrected on the next connect.
    w.release();
    await run(const Duration(seconds: 70));
    reg.update(f.copyWith(whitePoints: stale));
    expect(reg.byId('f1')!.whitePoints, stale);
    w = manager.want('f1', WantReason.screen);
    await run(const Duration(seconds: 5));
    f = reg.byId('f1')!;
    expect(f.whitePoints, product);
    expect(manager.session('f1')!.fixture.whitePoints, product);
    // It persisted: a new registry over the same store reads it back.
    w.release();
    await sub.cancel();
    await store.flush();
    final FixtureRegistry again = FixtureRegistry(
      store: await JsonStore.open(dir),
      connections: newManager(),
    );
    expect(again.byId('f1')!.whitePoints, product);
    await again.dispose();
    await reg.dispose();
  });
}
