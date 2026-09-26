import 'package:electrobright/core/color/colour_engine.dart';
import 'package:electrobright/core/color/hsv.dart';
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
import 'package:electrobright/sessions/group_session.dart';
import 'package:electrobright/sim/eb_device_model.dart';
import 'package:electrobright/sim/sim_central.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _pump([int n = 30]) async {
  for (int i = 0; i < n; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// All Lights on simulated radios: an RGB, two identical RGBW lights (same
/// type and firmware), a tunable white and a single white.
void main() {
  const String rgb = 'fx-rgb', a = 'fx-rgbw-a', b = 'fx-rgbw-b';
  const String cct = 'fx-cct', w = 'fx-w';
  const Map<String, (String, String, EbFixtureSpec)> lights =
      <String, (String, String, EbFixtureSpec)>{
        rgb: ('dev-rgb', 'Desk', EbFixtureCatalog.rgb),
        a: ('dev-rgbw-a', 'Shelf', EbFixtureCatalog.rgbw),
        b: ('dev-rgbw-b', 'Window', EbFixtureCatalog.rgbw),
        cct: ('dev-cct', 'Kitchen', EbFixtureCatalog.cct),
        w: ('dev-w', 'Hallway', EbFixtureCatalog.w),
      };
  const int rainbow = 10;

  late ManualScheduler clock;
  late SimCentral central;
  late Discovery discovery;
  late ConnectionManager manager;
  late JsonStore store;
  late FixtureRegistry registry;
  late GroupSession group;

  Future<void> run(Duration d) async {
    const Duration step = Duration(milliseconds: 10);
    for (Duration t = Duration.zero; t < d; t += step) {
      await _pump(5);
      clock.advance(step);
    }
    await _pump();
  }

  /// Runs [d] of app time, then the command's result.
  Future<GroupResult> settle(
    Future<GroupResult> r, [
    Duration d = const Duration(seconds: 2),
  ]) async {
    await run(d);
    return r;
  }

  Future<void> build({
    int? maxConnections,
    Set<String> favourites = const {},
  }) async {
    clock = ManualScheduler();
    central = SimCentral(
      scheduler: clock,
      fixtures: <SimFixture>[
        for (final (String dev, String _, EbFixtureSpec spec) in lights.values)
          SimFixture.electroBright(id: dev, fixture: spec),
      ],
    );
    discovery = Discovery(central: central, scheduler: clock, isAndroid: false);
    manager = ConnectionManager(
      central: central,
      discovery: discovery,
      scheduler: clock,
      policy: ConnectionPolicy(
        isAndroid: false,
        maxConnections: maxConnections,
      ),
    );
    store = JsonStore.memory();
    registry = FixtureRegistry(store: store, connections: manager);
    for (final MapEntry<String, (String, String, EbFixtureSpec)> e
        in lights.entries) {
      registry.add(
        Fixture(
          id: e.key,
          deviceId: e.value.$1,
          name: e.value.$2,
          layout: e.value.$3.layout,
          driver: DriverKind.electroBright,
          addedAt: DateTime(2026),
          favourite: favourites.contains(e.key),
        ),
      );
    }
    group = GroupSession(
      registry: registry,
      connections: manager,
      store: store,
      scheduler: clock,
    );
    await _pump();
  }

  tearDown(() async {
    group.dispose();
    await registry.dispose();
    await manager.dispose();
    await discovery.dispose();
    central.dispose();
  });

  /// The simulated light of a saved one (by fixture id).
  EbDeviceModel twin(String id) => central.fixtures
      .firstWhere((SimFixture f) => f.id == lights[id]!.$1)
      .model;
  FixtureSession session(String id) => manager.session(id)!;

  Future<void> activateAll() async {
    group.activate();
    await run(const Duration(seconds: 10));
    expect(group.status.ready, 5);
  }

  test(
    'a colour reaches every light; white-only lights follow as white',
    () async {
      await build();
      await activateAll();
      const HsvIntent red = HsvIntent(Hsv(0, 1, 0.5));
      final GroupResult r = await settle(group.setColour(red));
      expect(r, const GroupResult(ok: 5));

      ChannelColor encoded(String id, ColourIntent i) =>
          ColourEngine(registry.byId(id)!.whitePoints)
              .encode(i, registry.byId(id)!.layout);
      for (final String id in <String>[rgb, a, b]) {
        expect(twin(id).scene.color, encoded(id, red), reason: id);
        expect(twin(id).scene.color[1], 0, reason: id);
        expect(session(id).status.colourPick?.intent, red, reason: id);
      }
      // White at the colour's level on the lights without colour LEDs.
      for (final String id in <String>[cct, w]) {
        expect(
          twin(id).scene.color,
          encoded(id, const WhiteIntent(4000, 0.5)),
          reason: id,
        );
        expect(
          session(id).status.colourPick?.intent,
          isA<WhiteIntent>().having((WhiteIntent i) => i.level, 'level', 0.5),
          reason: id,
        );
      }
      expect(twin(w).scene.color, ChannelColor(ChannelLayout.w, <int>[128]));
      expect(group.look.colour, const Common<ColourIntent>.of(red));
    },
  );

  test('an effect goes only to the lights whose firmware has it', () async {
    await build();
    await activateAll();
    final GroupResult r = await settle(group.setMode(rainbow));
    // The W firmware has no Rainbow (MODES=1DFF); the CCT firmware reports
    // every mode.
    expect(r, const GroupResult(ok: 4, skipped: 1));
    for (final String id in <String>[rgb, a, b, cct]) {
      expect(twin(id).scene.mode, rainbow, reason: id);
    }
    expect(twin(w).scene.mode, 1);
    expect(group.look.mode, const Common<int>.mixed());
  });

  test('brightness, power and the sleep timer reach all five', () async {
    await build();
    await activateAll();
    await settle(group.setBrightness(100));
    for (final String id in lights.keys) {
      expect(twin(id).scene.brightness, 100, reason: id);
    }
    expect(group.look.brightness, const Common<int>.of(100));

    expect(await settle(group.setPower(on: false)), const GroupResult(ok: 5));
    for (final String id in lights.keys) {
      expect(twin(id).sleeping, isTrue, reason: id);
    }
    expect(group.look.anyOn, isFalse);
    await settle(group.setPower(on: true));
    expect(group.look.anyOn, isTrue);

    expect(await settle(group.setTimer(600)), const GroupResult(ok: 5));
    for (final String id in lights.keys) {
      expect(twin(id).timerActive, isTrue, reason: id);
    }
    expect(group.look.timerDeadline.value, isNotNull);
    expect(await settle(group.setTimer(0)), const GroupResult(ok: 5));
    for (final String id in lights.keys) {
      expect(twin(id).timerActive, isFalse, reason: id);
    }
    expect(group.look.timerDeadline, const Common<Duration>.none());
  });

  test('two identical RGBW lights are commanded and reported apart', () async {
    await build();
    await activateAll();
    expect(group.status.members.map((GroupMember m) => m.id), <String>[
      rgb,
      a,
      b,
      cct,
      w,
    ]);
    group.setExcluded(b, excluded: true);
    await run(const Duration(seconds: 1));
    expect(group.status.total, 4);
    expect(
      group.status.members.map((GroupMember m) => m.id),
      isNot(contains(b)),
    );

    final ChannelColor before = twin(b).scene.color;
    const HsvIntent green = HsvIntent(Hsv(120, 1, 1));
    expect(await settle(group.setColour(green)), const GroupResult(ok: 4));
    expect(twin(a).scene.color[1], 255);
    expect(twin(b).scene.color, before);

    // Taken back in while active: it catches up.
    group.setExcluded(b, excluded: false);
    await run(const Duration(seconds: 2));
    expect(twin(b).scene.color, twin(a).scene.color);
  });

  test('a light that becomes ready catches up in order; nothing replays '
      'after deactivate', () async {
    await build();
    final ChannelColor start = twin(b).scene.color;
    central.setAvailable(lights[b]!.$1, available: false);
    group.activate();
    await run(const Duration(seconds: 10));
    expect(group.status.ready, 4);
    expect(session(b).status.isReady, isFalse);

    await settle(group.setColour(const HsvIntent(Hsv(240, 1, 1))));
    // The look is the newest of colour and mode: the mode replaces it.
    await settle(group.setMode(rainbow));
    await settle(group.setBrightness(77));
    await settle(group.setPower(on: false));

    central.setAvailable(lights[b]!.$1, available: true);
    await run(const Duration(seconds: 20));
    expect(session(b).status.isReady, isTrue);
    expect(twin(b).scene.mode, rainbow);
    expect(twin(b).scene.color, start, reason: 'no blue replayed');
    expect(twin(b).scene.brightness, 77);
    // Power after brightness: it stays off.
    expect(twin(b).sleeping, isTrue);

    // A timer catches up as the time it has left.
    await settle(group.setPower(on: true));
    central.setAvailable(lights[cct]!.$1, available: false);
    await run(const Duration(seconds: 2));
    await settle(group.setTimer(600));
    await run(const Duration(seconds: 30));
    central.setAvailable(lights[cct]!.$1, available: true);
    await run(const Duration(seconds: 20));
    expect(session(cct).status.isReady, isTrue);
    expect(twin(cct).timerActive, isTrue);
    expect(twin(cct).timerRemainingSec, inInclusiveRange(530, 575));

    // After deactivate nothing is remembered.
    central.setAvailable(lights[w]!.$1, available: false);
    await run(const Duration(seconds: 2));
    await settle(group.setBrightness(33));
    group.deactivate();
    central.setAvailable(lights[w]!.$1, available: true);
    final Want want = manager.want(w, WantReason.screen);
    await run(const Duration(seconds: 20));
    expect(session(w).status.isReady, isTrue);
    expect(twin(w).scene.brightness, isNot(33));
    want.release();
  });

  test(
    'with room for three: favourites first, two reported limited out',
    () async {
      await build(maxConnections: 3, favourites: <String>{cct, w});
      group.activate();
      await run(const Duration(seconds: 15));
      final GroupStatus st = group.status;
      expect(st.total, 5);
      expect(st.limitedOut, 2);
      expect(
        st.members
            .where((GroupMember m) => m.limitedOut)
            .map((GroupMember m) => m.id),
        <String>[a, b],
      );
      expect(st.ready, 3);
      for (final String id in <String>[cct, w, rgb]) {
        expect(session(id).status.isReady, isTrue, reason: id);
      }
    },
  );

  test('deactivate releases every connection; a forgotten light leaves the '
      'excluded list', () async {
    await build();
    await activateAll();
    group.deactivate();
    group.deactivate(); // idempotent
    await run(const Duration(seconds: 65));
    for (final String id in lights.keys) {
      expect(session(id).status.phase, LinkPhase.idle, reason: id);
    }
    expect(group.status.limitedOut, 0);

    group.setExcluded(b, excluded: true);
    expect(store.read(GroupSession.excludedKey), <String>[b]);
    await registry.forget(b);
    await _pump();
    expect(store.read(GroupSession.excludedKey), isEmpty);
    expect(
      group.status.members.map((GroupMember m) => m.id),
      isNot(contains(b)),
    );
  });
}
