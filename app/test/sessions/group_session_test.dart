import 'dart:async';
import 'dart:convert';

import 'package:electrobright/core/color/colour_engine.dart';
import 'package:electrobright/core/color/hsv.dart';
import 'package:electrobright/core/model/channel_color.dart';
import 'package:electrobright/core/model/channel_layout.dart';
import 'package:electrobright/core/model/fixture.dart';
import 'package:electrobright/core/protocol/eb/eb_fixture_catalog.dart';
import 'package:electrobright/core/protocol/eb/eb_scene.dart';
import 'package:electrobright/core/store/json_store.dart';
import 'package:electrobright/core/util/scheduler.dart';
import 'package:electrobright/drivers/electrobright/eb_session.dart';
import 'package:electrobright/sessions/connection_manager.dart';
import 'package:electrobright/sessions/discovery.dart';
import 'package:electrobright/sessions/fixture_registry.dart';
import 'package:electrobright/sessions/fixture_session.dart';
import 'package:electrobright/sessions/group_capabilities.dart';
import 'package:electrobright/sessions/group_presets.dart';
import 'package:electrobright/sessions/group_session.dart';
import 'package:electrobright/sessions/rituals.dart';
import 'package:electrobright/sim/eb_device_model.dart';
import 'package:electrobright/sim/sim_central.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _pump([int n = 30]) async {
  for (int i = 0; i < n; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// The colour and white groups on simulated radios. By default: an RGB, two
/// identical RGBW lights (same type and firmware) and an RGB+CCT in the
/// colour group; a tunable white and a single white in the white group.
void main() {
  const String rgb = 'fx-rgb', rgb2 = 'fx-rgb-2';
  const String a = 'fx-rgbw-a', b = 'fx-rgbw-b';
  const String x = 'fx-rgbcct', x2 = 'fx-rgbcct-2';
  const String cct = 'fx-cct', cct2 = 'fx-cct-2';
  const String w = 'fx-w', w2 = 'fx-w-2';
  // An RGB light whose firmware has neither Fireworks nor Police.
  const String basic = 'fx-rgb-basic';
  const EbFixtureSpec rgbBasic = EbFixtureSpec(
    folder: 'ElectroBright_RGB',
    fwsimName: 'rgb',
    layout: ChannelLayout.rgb,
    modelId: 'EB-C3-RGB-V1',
    bleName: 'ElectroBright_C3_RGB_V1',
    capsReply:
        'CAPS:PROTOCOL=1,PWM=14,GAMMA=2.2,MASTER=PERCEPTUAL,PRESETS=15,'
        'LAYOUT=RGB,MODES=17F7',
    nvsNamespace: 'eb3rgb',
    modeMask: 0x17F7,
    colorValues: <int>[255, 255, 255],
    policeAValues: <int>[255, 165, 0],
    policeBValues: <int>[255, 255, 255],
    legacyFrames: false,
  );
  const Map<String, (String, String, EbFixtureSpec)> catalog =
      <String, (String, String, EbFixtureSpec)>{
        rgb: ('dev-rgb', 'Desk', EbFixtureCatalog.rgb),
        rgb2: ('dev-rgb-2', 'Desk 2', EbFixtureCatalog.rgb),
        a: ('dev-rgbw-a', 'Shelf', EbFixtureCatalog.rgbw),
        b: ('dev-rgbw-b', 'Window', EbFixtureCatalog.rgbw),
        x: ('dev-rgbcct', 'Sofa', EbFixtureCatalog.rgbcct),
        x2: ('dev-rgbcct-2', 'Sofa 2', EbFixtureCatalog.rgbcct),
        cct: ('dev-cct', 'Kitchen', EbFixtureCatalog.cct),
        cct2: ('dev-cct-2', 'Kitchen 2', EbFixtureCatalog.cct),
        w: ('dev-w', 'Hallway', EbFixtureCatalog.w),
        w2: ('dev-w-2', 'Hallway 2', EbFixtureCatalog.w),
        basic: ('dev-rgb-basic', 'Basic', rgbBasic),
      };
  const List<String> defaults = <String>[rgb, a, b, x, cct, w];
  const List<String> colourDefaults = <String>[rgb, a, b, x];
  const int rainbow = 10;

  late ManualScheduler clock;
  late SimCentral central;
  late Discovery discovery;
  late ConnectionManager manager;
  late JsonStore store;
  late FixtureRegistry registry;
  late GroupSessions groups;
  GroupSession colour() => groups.colour;
  GroupSession white() => groups.white;
  bool built = false;

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

  Fixture fixtureOf(String id, {bool favourite = false}) => Fixture(
    id: id,
    deviceId: catalog[id]!.$1,
    name: catalog[id]!.$2,
    layout: catalog[id]!.$3.layout,
    driver: DriverKind.electroBright,
    addedAt: DateTime(2026),
    favourite: favourite,
  );

  Future<void> build({
    List<String> ids = defaults,
    int? maxConnections,
    Set<String> favourites = const {},
  }) async {
    clock = ManualScheduler();
    central = SimCentral(
      scheduler: clock,
      fixtures: <SimFixture>[
        for (final (String dev, String _, EbFixtureSpec spec) in catalog.values)
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
    for (final String id in ids) {
      registry.add(fixtureOf(id, favourite: favourites.contains(id)));
    }
    groups = GroupSessions(
      registry: registry,
      connections: manager,
      store: store,
      scheduler: clock,
    );
    built = true;
    await _pump();
  }

  tearDown(() async {
    if (!built) return;
    built = false;
    groups.dispose();
    await registry.dispose();
    await manager.dispose();
    await discovery.dispose();
    central.dispose();
  });

  /// The simulated light of a saved one (by fixture id).
  EbDeviceModel twin(String id) => central.fixtures
      .firstWhere((SimFixture f) => f.id == catalog[id]!.$1)
      .model;
  FixtureSession session(String id) => manager.session(id)!;
  ChannelColor encoded(String id, ColourIntent i) =>
      ColourEngine(registry.byId(id)!.whitePoints)
          .encode(i, registry.byId(id)!.layout);
  void available(String id, {required bool on}) =>
      central.setAvailable(catalog[id]!.$1, available: on);

  Future<void> activate(GroupSession g) async {
    g.activate();
    await run(const Duration(seconds: 10));
    expect(g.active, isTrue);
    expect(g.status.ready, g.status.total);
  }

  // ---- membership --------------------------------------------------------------------

  test('every light lands in its own group; identical lights are separate '
      'members', () async {
    await build();
    List<String> ids(GroupSession g) =>
        g.status.members.map((GroupMember m) => m.id).toList();
    expect(ids(colour()), <String>[rgb, a, b, x]);
    expect(ids(white()), <String>[cct, w]);
    expect(colour().status.exists && white().status.exists, isTrue);
    await activate(colour());
    // The two RGBW lights are commanded and reported apart.
    colour().setExcluded(b, excluded: true);
    expect(ids(colour()), <String>[rgb, a, x]);
    expect(colour().status.excluded, <String>[b]);
    final ChannelColor before = twin(b).scene.color;
    expect(
      await settle(colour().setColour(const HsvIntent(Hsv(120, 1, 1)))),
      const GroupResult(ok: 3),
    );
    expect(twin(a).scene.color[1], 255);
    expect(twin(b).scene.color, before);
    // Taken back in while active: it catches up.
    colour().setExcluded(b, excluded: false);
    await run(const Duration(seconds: 2));
    expect(twin(b).scene.color, twin(a).scene.color);
    // A white light can't be left out of (or trimmed in) the colour group.
    colour().setExcluded(w, excluded: true);
    colour().setTrim(w, 0.5);
    expect(colour().isExcluded(w), isFalse);
    expect(colour().trimOf(w), 1);
  });

  test('a group exists with 2 or more lights; new lights join their group '
      'automatically', () async {
    await build(ids: <String>[rgb, a, cct]);
    expect(colour().status.exists, isTrue);
    expect(white().status.exists, isFalse);
    white().activate();
    expect(white().active, isFalse, reason: 'no group of one');

    registry.add(fixtureOf(w));
    await _pump();
    expect(white().status.exists, isTrue);
    expect(white().status.members.map((GroupMember m) => m.id), <String>[
      cct,
      w,
    ]);
    registry.add(fixtureOf(x));
    await _pump();
    expect(colour().status.members.map((GroupMember m) => m.id), <String>[
      rgb,
      a,
      x,
    ]);

    // Down to one light while open: the group is gone.
    await activate(white());
    await registry.forget(w);
    await _pump();
    expect(white().status.exists, isFalse);
    expect(white().active, isFalse);
  });

  test('activating one group deactivates the other', () async {
    await build();
    await activate(colour());
    await settle(colour().setBrightness(99));
    white().activate();
    await run(const Duration(seconds: 10));
    expect(white().active, isTrue);
    expect(colour().active, isFalse);
    expect(colour().status.active, isFalse);
    expect(white().status.ready, 2);
    colour().activate();
    await run(const Duration(seconds: 1));
    expect(colour().active, isTrue);
    expect(white().active, isFalse);
  });

  // ---- colour group ------------------------------------------------------------------

  const List<List<String>> mixes = <List<String>>[
    <String>[rgb, rgb2],
    <String>[a, b],
    <String>[x, x2],
    <String>[rgb, a],
    <String>[rgb, x],
    <String>[a, x],
    <String>[rgb, a, x],
  ];
  for (final List<String> mix in mixes) {
    test('colour group ${mix.join(' + ')}: a pick reaches every light with '
        'its white LEDs at 0', () async {
      await build(ids: mix);
      await activate(colour());
      // White LEDs lit beforehand (by the app, not the user).
      for (final String id in mix) {
        final ChannelLayout l = registry.byId(id)!.layout;
        session(id).setColor(
          ChannelColor(l, List<int>.filled(l.n, 200)),
          origin: CommandOrigin.system,
        );
      }
      await run(const Duration(seconds: 1));
      const HsvIntent pick = HsvIntent(Hsv(200, 1, 1), white: 0.6);
      const HsvIntent sent = HsvIntent(Hsv(200, 1, 1));
      expect(
        await settle(colour().setColour(pick)),
        GroupResult(ok: mix.length),
      );
      for (final String id in mix) {
        final ChannelColor c = twin(id).scene.color;
        expect(c, encoded(id, sent), reason: id);
        for (int ch = 3; ch < c.layout.n; ch++) {
          expect(c[ch], 0, reason: '$id channel $ch');
        }
        expect(session(id).status.colourPick?.intent, sent, reason: id);
      }
      expect(colour().look.colour, const Common<ColourIntent>.of(sent));
      // No temperature in the colour group.
      expect(await settle(colour().setTemperature(3000)), const GroupResult());
      for (final String id in mix) {
        expect(twin(id).scene.color, encoded(id, sent), reason: id);
      }
    });
  }

  // ---- white group -------------------------------------------------------------------

  test('white group, W only: no temperature; brightness, power, mode and '
      'timer reach both', () async {
    await build(ids: <String>[w, w2]);
    await activate(white());
    final ChannelColor before = twin(w).scene.color;
    expect(
      await settle(white().setTemperature(3000)),
      const GroupResult(skipped: 2),
    );
    expect(
      await settle(white().setColour(const HsvIntent(Hsv(0, 1, 1)))),
      const GroupResult(),
    );
    expect(twin(w).scene.color, before);
    expect(twin(w2).scene.color, before);
    await settle(white().setBrightness(90));
    expect(await settle(white().setMode(2)), const GroupResult(ok: 2));
    // The W firmware has no Rainbow (MODES=1DFF).
    expect(
      await settle(white().setMode(rainbow)),
      const GroupResult(skipped: 2),
    );
    expect(await settle(white().setTimer(600)), const GroupResult(ok: 2));
    for (final String id in <String>[w, w2]) {
      expect(twin(id).scene.brightness, 90, reason: id);
      expect(twin(id).scene.mode, 2, reason: id);
      expect(twin(id).timerActive, isTrue, reason: id);
    }
    expect(await settle(white().setPower(on: false)), const GroupResult(ok: 2));
    expect(twin(w).sleeping && twin(w2).sleeping, isTrue);
  });

  test('white group, CCT only: the temperature reaches both, clamped to '
      'their range', () async {
    await build(ids: <String>[cct, cct2]);
    await activate(white());
    final int wwK = registry.byId(cct)!.whitePoints.wwK;
    expect(
      await settle(white().setTemperature(2000)),
      const GroupResult(ok: 2),
    );
    final WhiteIntent warmest = WhiteIntent(wwK.toDouble(), 1);
    for (final String id in <String>[cct, cct2]) {
      expect(twin(id).scene.color, encoded(id, warmest), reason: id);
      expect(session(id).status.colourPick?.intent, warmest, reason: id);
    }
    await settle(white().setTemperature(5000));
    for (final String id in <String>[cct, cct2]) {
      expect(twin(id).scene.color, encoded(id, const WhiteIntent(5000, 1)));
    }
    expect(
      white().look.colour,
      const Common<ColourIntent>.of(WhiteIntent(5000, 1)),
    );
  });

  test('white group, CCT + W: the temperature reaches the CCT light only; '
      'the W light gets brightness, power, mode and timer', () async {
    await build(ids: <String>[cct, w]);
    await activate(white());
    final ChannelColor wBefore = twin(w).scene.color;
    expect(
      await settle(white().setTemperature(4000)),
      const GroupResult(ok: 1, skipped: 1),
    );
    expect(twin(cct).scene.color, encoded(cct, const WhiteIntent(4000, 1)));
    expect(twin(w).scene.color, wBefore);
    expect(white().isFollowing(w), isFalse, reason: 'never reached');
    await settle(white().setBrightness(120));
    expect(await settle(white().setMode(2)), const GroupResult(ok: 2));
    expect(
      await settle(white().setMode(rainbow)),
      const GroupResult(ok: 1, skipped: 1),
    );
    expect(await settle(white().setTimer(600)), const GroupResult(ok: 2));
    for (final String id in <String>[cct, w]) {
      expect(twin(id).scene.brightness, 120, reason: id);
      expect(twin(id).timerActive, isTrue, reason: id);
    }
    expect(twin(w).scene.mode, 2);
    expect(twin(cct).scene.mode, rainbow);
    expect(twin(w).scene.color, wBefore);
    expect(await settle(white().setPower(on: false)), const GroupResult(ok: 2));
    expect(twin(cct).sleeping && twin(w).sleeping, isTrue);
    expect(white().look.anyOn, isFalse);
  });

  // ---- sending, catch-up and connections --------------------------------------------

  test('a light that becomes ready catches up in order; nothing replays '
      'after deactivate', () async {
    await build();
    final ChannelColor start = twin(b).scene.color;
    available(b, on: false);
    colour().activate();
    await run(const Duration(seconds: 10));
    expect(colour().status.ready, 3);

    await settle(colour().setColour(const HsvIntent(Hsv(240, 1, 1))));
    // The look is the newest of colour and mode: the mode replaces it.
    await settle(colour().setMode(rainbow));
    await settle(colour().setBrightness(77));
    await settle(colour().setPower(on: false));

    available(b, on: true);
    await run(const Duration(seconds: 20));
    expect(session(b).status.isReady, isTrue);
    expect(twin(b).scene.mode, rainbow);
    expect(twin(b).scene.color, start, reason: 'no blue replayed');
    expect(twin(b).scene.brightness, 77);
    // Power after brightness: it stays off.
    expect(twin(b).sleeping, isTrue);

    // A timer catches up as the time it has left.
    await settle(colour().setPower(on: true));
    available(x, on: false);
    await run(const Duration(seconds: 2));
    await settle(colour().setTimer(600));
    await run(const Duration(seconds: 30));
    available(x, on: true);
    await run(const Duration(seconds: 20));
    expect(session(x).status.isReady, isTrue);
    expect(twin(x).timerActive, isTrue);
    expect(twin(x).timerRemainingSec, inInclusiveRange(530, 575));

    // After deactivate nothing is remembered.
    available(rgb, on: false);
    await run(const Duration(seconds: 2));
    await settle(colour().setBrightness(33));
    colour().deactivate();
    available(rgb, on: true);
    final Want want = manager.want(rgb, WantReason.screen);
    await run(const Duration(seconds: 20));
    expect(session(rgb).status.isReady, isTrue);
    expect(twin(rgb).scene.brightness, isNot(33));
    want.release();
  });

  test(
    'with room for two: favourites first, two reported limited out',
    () async {
      await build(maxConnections: 2, favourites: <String>{x, b});
      colour().activate();
      await run(const Duration(seconds: 15));
      final GroupStatus st = colour().status;
      expect(st.total, 4);
      expect(st.limitedOut, 2);
      expect(
        st.members
            .where((GroupMember m) => m.limitedOut)
            .map((GroupMember m) => m.id),
        <String>[rgb, a],
      );
      expect(st.ready, 2);
    },
  );

  test('deactivate releases every connection; a forgotten light leaves the '
      'excluded list', () async {
    await build();
    await activate(colour());
    colour().deactivate();
    colour().deactivate(); // idempotent
    await run(const Duration(seconds: 65));
    for (final String id in colourDefaults) {
      expect(session(id).status.phase, LinkPhase.idle, reason: id);
    }
    expect(colour().status.limitedOut, 0);

    colour().setExcluded(b, excluded: true);
    white().setExcluded(w, excluded: true);
    expect(store.read(GroupSession.excludedKey), <String>[b, w]);
    await registry.forget(b);
    await _pump();
    expect(store.read(GroupSession.excludedKey), <String>[w]);
    expect(
      colour().status.members.map((GroupMember m) => m.id),
      isNot(contains(b)),
    );
  });

  test('a light\'s brightness is the master at its trim, never 0 while '
      'the master is on', () {
    expect(GroupSession.trimmed(200, 1), 200);
    expect(GroupSession.trimmed(200, 0.5), 100);
    expect(GroupSession.trimmed(0, 0.5), 0);
    for (int m = 1; m <= 255; m++) {
      for (final double t in <double>[0.05, 0.3, 0.7, 1]) {
        expect(GroupSession.trimmed(m, t), greaterThan(0), reason: '$m $t');
      }
    }
  });

  test('trimmed lights read as one master, not "Mixed"', () {
    for (int m = 0; m <= 255; m++) {
      final List<double> trims = <double>[1, 0.5, 0.05];
      final Common<int> c = GroupSession.commonMaster(<(int, double)>[
        for (final double t in trims) (GroupSession.trimmed(m, t), t),
      ]);
      expect(c, Common<int>.of(m), reason: '$m');
    }
    // Only trimmed lights: some master explains them all.
    for (int m = 1; m <= 255; m++) {
      final List<(int, double)> l = <(int, double)>[
        (GroupSession.trimmed(m, 0.7), 0.7),
        (GroupSession.trimmed(m, 0.3), 0.3),
      ];
      final Common<int> c = GroupSession.commonMaster(l);
      expect(c.mixed, isFalse, reason: '$m');
      for (final (int b, double t) in l) {
        expect(GroupSession.trimmed(c.value!, t), b, reason: '$m');
      }
    }
    expect(
      GroupSession.commonMaster(<(int, double)>[(100, 1), (80, 1)]),
      const Common<int>.mixed(),
    );
  });

  test('trims apply per light; master 0 turns every light off', () async {
    await build();
    await activate(colour());
    colour().setTrim(a, 0.5);
    await settle(colour().setBrightness(200));
    expect(twin(a).scene.brightness, 100);
    for (final String id in <String>[rgb, b, x]) {
      expect(twin(id).scene.brightness, 200, reason: id);
    }
    expect(colour().look.brightness, const Common<int>.of(200));
    // A new trim reaches that light alone, at once.
    colour().setTrim(a, 0.25);
    await run(const Duration(seconds: 1));
    expect(twin(a).scene.brightness, 50);
    expect(twin(b).scene.brightness, 200);
    expect(colour().trimOf(a), 0.25);
    expect(colour().look.brightness, const Common<int>.of(200));
    await settle(colour().setBrightness(0));
    for (final String id in colourDefaults) {
      expect(twin(id).sleeping, isTrue, reason: id);
    }
  });

  // ---- own settings ------------------------------------------------------------------

  test('a user change on a following light detaches it; group and system '
      'changes, trim, timer, rename and identify don\'t', () async {
    await build();
    await activate(colour());
    await settle(colour().setBrightness(180));
    for (final String id in colourDefaults) {
      expect(colour().isFollowing(id), isTrue, reason: id);
    }
    // Not the user on the light's own controls: still following.
    session(a).setColor(twin(a).scene.color, origin: CommandOrigin.group);
    unawaited(session(b).setMode(3, origin: CommandOrigin.system));
    unawaited(session(rgb).setTimer(600));
    registry.update(registry.byId(x)!.copyWith(name: 'Pantry'));
    unawaited(session(x).identify());
    colour().setTrim(rgb, 0.4);
    await run(const Duration(seconds: 3));
    for (final String id in colourDefaults) {
      expect(colour().isOwn(id), isFalse, reason: id);
      expect(colour().isFollowing(id), isTrue, reason: id);
    }

    // The user, on each light's own controls: colour, brightness, mode,
    // power, preset.
    final Future<EbPresetResult> saved = session(x).presetSave(0);
    await run(const Duration(seconds: 2));
    await saved;
    expect(colour().isOwn(x), isFalse, reason: 'saving a preset is no change');
    session(a).setColor(twin(a).scene.color);
    session(rgb).setBrightness(50);
    unawaited(session(b).setMode(4));
    unawaited(session(x).presetLoad(0));
    await run(const Duration(seconds: 2));
    for (final String id in colourDefaults) {
      expect(colour().isOwn(id), isTrue, reason: id);
      expect(colour().isFollowing(id), isFalse, reason: id);
    }
    expect(
      colour().status.members.every((GroupMember m) => m.own && !m.following),
      isTrue,
    );
    // Power on the light's own controls (Home's tile toggle) detaches too.
    await activate(white());
    await settle(white().setBrightness(100));
    unawaited(session(cct).setPower(on: false));
    await run(const Duration(seconds: 1));
    expect(white().isOwn(cct), isTrue);
  });

  test('a light a group command never reached is not detached; own lights '
      'are skipped; rejoin catches up', () async {
    await build(ids: <String>[cct, w]);
    await activate(white());
    // Only the CCT light takes a temperature.
    await settle(white().setTemperature(3500));
    expect(white().isFollowing(cct), isTrue);
    expect(white().isFollowing(w), isFalse);
    unawaited(session(w).setMode(3));
    session(cct).setBrightness(60);
    await run(const Duration(seconds: 1));
    expect(white().isOwn(w), isFalse, reason: 'never followed');
    expect(white().isOwn(cct), isTrue);

    await settle(white().setMode(2));
    expect(twin(cct).scene.mode, isNot(2), reason: 'own lights are skipped');
    expect(twin(w).scene.mode, 2);

    white().rejoin(cct);
    await run(const Duration(seconds: 2));
    expect(white().isOwn(cct), isFalse);
    expect(white().isFollowing(cct), isTrue);
    expect(twin(cct).scene.mode, 2, reason: 'caught up');

    // Group closed: a change on the light's own screen still counts.
    white().deactivate();
    unawaited(session(w).setMode(5));
    await run(const Duration(seconds: 1));
    expect(white().isOwn(w), isTrue);

    // Rejoin all: every light back, excluded ones too, and caught up.
    white().setExcluded(cct, excluded: true);
    await activate(white());
    await settle(white().setMode(4));
    white().rejoinAll();
    await run(const Duration(seconds: 2));
    for (final String id in <String>[cct, w]) {
      expect(white().isOwn(id) || white().isExcluded(id), isFalse, reason: id);
      expect(white().isFollowing(id), isTrue, reason: id);
      expect(twin(id).scene.mode, 4, reason: id);
    }
  });

  test(
    'rejoining with no group look stored does not make a light follow',
    () async {
      await build();
      await activate(colour());
      colour().setExcluded(b, excluded: true);
      colour().deactivate();
      colour().rejoinAll();
      await run(const Duration(seconds: 1));
      expect(colour().isExcluded(b), isFalse);
      expect(colour().isFollowing(b), isFalse);
      expect(store.read(GroupSession.lookKey(GroupKind.colour)), isNull);
    },
  );

  /// A new GroupSessions on the same store: the app restarted.
  void restart() {
    groups.dispose();
    groups = GroupSessions(
      registry: registry,
      connections: manager,
      store: store,
      scheduler: clock,
    );
  }

  test('colour group: rejoining in a fresh activation applies the stored '
      'look, then the master at its trim, then power', () async {
    await build();
    await activate(colour());
    const HsvIntent blue = HsvIntent(Hsv(240, 1, 1));
    await settle(colour().setColour(blue));
    await settle(colour().setMode(3));
    await settle(colour().setSpeed(3, 8));
    await settle(colour().setFrequency(3, 2));
    await settle(colour().setColorMode(EbColorModeKind.club, 1));
    await settle(colour().setBrightness(150));
    colour().setTrim(a, 0.5);
    await run(const Duration(seconds: 1));
    // The user takes Shelf elsewhere on its own screen.
    session(a).setColor(encoded(a, const HsvIntent(Hsv(0, 1, 1))));
    unawaited(session(a).setMode(5));
    session(a).setBrightness(40);
    await run(const Duration(seconds: 2));
    expect(colour().isOwn(a), isTrue);
    colour().deactivate();
    restart();

    await activate(colour());
    // Own lights don't count toward the group's look.
    expect(colour().look.brightness, const Common<int>.of(150));
    expect(colour().look.master, 150);
    colour().rejoin(a);
    await run(const Duration(seconds: 3));
    expect(twin(a).scene.color, encoded(a, blue));
    expect(twin(a).scene.mode, 3);
    expect(twin(a).scene.speeds[2], 8);
    expect(twin(a).scene.frequencies[2], 2);
    expect(twin(a).scene.clubColorMode, 1);
    expect(twin(a).scene.brightness, GroupSession.trimmed(150, 0.5));
    expect(twin(a).sleeping, isFalse);
    expect(colour().isFollowing(a), isTrue);
    expect(colour().isOwn(a), isFalse);
    // It matches the group at once: nothing reads as mixed.
    expect(colour().look.brightness, const Common<int>.of(150));
    expect(colour().look.mode, const Common<int>.of(3));
    expect(colour().look.colour, const Common<ColourIntent>.of(blue));
  });

  test('white group: rejoining in a fresh activation applies the stored '
      'temperature, mode and master', () async {
    await build(ids: <String>[cct, cct2, w]);
    await activate(white());
    await settle(white().setTemperature(3000));
    await settle(white().setMode(2));
    await settle(white().setBrightness(120));
    await settle(white().setPower(on: false));
    session(cct).setBrightness(30);
    unawaited(session(cct).setMode(4));
    await run(const Duration(seconds: 2));
    expect(white().isOwn(cct), isTrue);
    white().deactivate();
    restart();

    await activate(white());
    white().rejoin(cct);
    await run(const Duration(seconds: 3));
    expect(twin(cct).scene.color, twin(cct2).scene.color);
    expect(twin(cct).scene.mode, 2);
    expect(twin(cct).scene.brightness, 120);
    expect(twin(cct).sleeping, isTrue, reason: 'power comes last');
    expect(white().isFollowing(cct), isTrue);
    expect(white().look.brightness, const Common<int>.of(120));
    expect(white().look.mode, const Common<int>.of(2));
  });

  test('Rejoin all updates every rejoined light\'s actual state; a light '
      'not connected gets it when it connects with the group open', () async {
    await build();
    await activate(colour());
    await settle(colour().setBrightness(200));
    colour().setExcluded(b, excluded: true);
    await settle(colour().setMode(rainbow));
    await settle(colour().setBrightness(90));
    unawaited(session(a).setMode(5));
    unawaited(session(x).setMode(6));
    await run(const Duration(seconds: 2));
    expect(colour().isOwn(a) && colour().isOwn(x), isTrue);
    available(x, on: false);
    await run(const Duration(seconds: 3));
    colour().deactivate();
    restart();

    colour().activate();
    await run(const Duration(seconds: 10));
    expect(colour().status.ready, 2, reason: 'b is left out, x is away');
    colour().rejoinAll();
    await run(const Duration(seconds: 3));
    for (final String id in <String>[rgb, a, b]) {
      expect(twin(id).scene.mode, rainbow, reason: id);
      expect(twin(id).scene.brightness, 90, reason: id);
      expect(colour().isFollowing(id), isTrue, reason: id);
    }
    expect(twin(x).scene.mode, 6, reason: 'not connected yet');
    expect(colour().isFollowing(x), isFalse);
    expect(store.read(GroupSession.rejoiningKey), <Object?>[x]);

    available(x, on: true);
    await run(const Duration(seconds: 20));
    expect(session(x).status.isReady, isTrue);
    expect(twin(x).scene.mode, rainbow);
    expect(twin(x).scene.brightness, 90);
    expect(colour().isFollowing(x), isTrue);
    expect(store.read(GroupSession.rejoiningKey), isEmpty);
    expect(colour().look.brightness, const Common<int>.of(90));
    expect(colour().look.mode, const Common<int>.of(rainbow));
  });

  test('a live level drag sends intermediate values to that light only; '
      'the release saves it', () async {
    await build();
    await activate(colour());
    await settle(colour().setBrightness(200));
    final Map<String, int> before = <String, int>{
      for (final String id in colourDefaults) id: twin(id).scene.brightness,
    };
    final List<int> seen = <int>[];
    colour().beginTrim(a);
    for (final double t in <double>[0.8, 0.6, 0.4, 0.3]) {
      colour().setTrim(a, t, live: true);
      await run(const Duration(milliseconds: 200));
      seen.add(twin(a).scene.brightness);
      expect(colour().trimOf(a), 1, reason: 'not saved mid-drag');
    }
    expect(seen, <int>[160, 120, 80, 60]);
    colour().setTrim(a, 0.3);
    colour().endTrim(a);
    await run(const Duration(seconds: 1));
    expect(colour().trimOf(a), 0.3);
    expect(twin(a).scene.brightness, 60);
    for (final String id in colourDefaults.where((String id) => id != a)) {
      expect(twin(id).scene.brightness, before[id], reason: id);
    }
    expect(colour().isOwn(a), isFalse, reason: 'a trim never detaches');
    expect(colour().isFollowing(a), isTrue);
  });

  test('own, following, excluded and trims of both groups survive a restart; '
      'a forgotten light leaves every list', () async {
    await build();
    await activate(colour());
    await settle(colour().setBrightness(150));
    session(a).setBrightness(40);
    white().setExcluded(w, excluded: true);
    colour().setTrim(b, 0.4);
    white().setTrim(cct, 0.6);
    await run(const Duration(seconds: 1));

    groups.dispose();
    groups = GroupSessions(
      registry: registry,
      connections: manager,
      store: store,
      scheduler: clock,
    );
    expect(colour().isOwn(a), isTrue);
    expect(colour().isFollowing(b), isTrue);
    expect(white().isExcluded(w), isTrue);
    expect(colour().trimOf(b), 0.4);
    expect(white().trimOf(cct), 0.6);

    for (final String id in <String>[a, b, w, cct]) {
      await registry.forget(id);
    }
    await _pump();
    for (final String key in <String>[
      GroupSession.excludedKey,
      GroupSession.followingKey,
      GroupSession.ownKey,
    ]) {
      final List<Object?> ids = store.read(key)! as List<Object?>;
      for (final String id in <String>[a, b, w, cct]) {
        expect(ids, isNot(contains(id)), reason: '$key $id');
      }
    }
    expect(store.read(GroupSession.trimKey), isEmpty);
  });

  // ---- presets -----------------------------------------------------------------------

  test('a preset keeps each following light\'s look and applies it per '
      'light, at its current trim', () async {
    await build();
    await activate(colour());
    await settle(colour().setBrightness(200));
    // Each light its own look (by the app: they keep following).
    const CommandOrigin sys = CommandOrigin.system;
    const HsvIntent red = HsvIntent(Hsv(0, 1, 1));
    session(rgb).setColor(encoded(rgb, red), intent: red, origin: sys);
    unawaited(session(a).setMode(rainbow, origin: sys));
    unawaited(session(a).setSpeed(rainbow, 8, origin: sys));
    unawaited(session(a).setFrequency(rainbow, 3, origin: sys));
    unawaited(session(x).setPower(on: false, origin: sys));
    await run(const Duration(seconds: 2));

    expect(colour().savePreset(0, 'Evening'), const GroupSaveResult(4, 4));
    final GroupPreset p = colour().presets[0]!;
    expect(p.name, 'Evening');
    expect(p.master, 200);
    expect(p.lights.keys, unorderedEquals(colourDefaults));
    expect(p.lights[rgb]!.colour, encoded(rgb, red));
    expect(p.lights[a]!.mode, rainbow);
    expect(p.lights[a]!.speed, 8);
    expect(p.lights[a]!.frequency, 3);
    expect(p.lights[x]!.on, isFalse);
    expect(p.lights[b]!.on, isTrue);

    // Something else entirely, and a new trim.
    await settle(colour().setColour(const HsvIntent(Hsv(240, 1, 1))));
    await settle(colour().setMode(2));
    await settle(colour().setPower(on: true));
    await settle(colour().setBrightness(50));
    colour().setTrim(b, 0.5);
    await run(const Duration(seconds: 1));

    expect(await settle(colour().applyPreset(0)), const GroupResult(ok: 4));
    expect(twin(rgb).scene.color, encoded(rgb, red));
    expect(twin(rgb).scene.mode, p.lights[rgb]!.mode);
    expect(twin(a).scene.mode, rainbow);
    expect(twin(a).scene.speeds[rainbow - 1], 8);
    expect(twin(a).scene.frequencies[rainbow - 1], 3);
    expect(twin(b).scene.color, p.lights[b]!.colour);
    expect(twin(rgb).scene.brightness, 200);
    expect(twin(b).scene.brightness, 100, reason: '200 at trim 0.5');
    expect(twin(x).sleeping, isTrue);
    expect(twin(rgb).sleeping, isFalse);
    expect(colour().status.activePreset, 0);
    for (final String id in colourDefaults) {
      expect(colour().isOwn(id), isFalse, reason: id);
    }
    // The next group command ends it.
    await settle(colour().setBrightness(120));
    expect(colour().status.activePreset, isNull);
  });

  test('applying skips own-settings and excluded lights, leaves lights not '
      'in the preset alone, and catches up late ones', () async {
    await build();
    await activate(colour());
    await settle(colour().setBrightness(200));
    await settle(colour().setColour(const HsvIntent(Hsv(0, 1, 1))));
    // x is away: saved 3 of 4.
    available(x, on: false);
    await run(const Duration(seconds: 3));
    expect(colour().savePreset(2, 'Red'), const GroupSaveResult(3, 4));
    expect(colour().presets[2]!.lights.keys, isNot(contains(x)));
    available(x, on: true);
    await run(const Duration(seconds: 20));
    expect(session(x).status.isReady, isTrue);

    const HsvIntent blue = HsvIntent(Hsv(240, 1, 1));
    await settle(colour().setColour(blue));
    await settle(colour().setBrightness(60));
    // a on its own settings, rgb left out, b away.
    session(a).setColor(encoded(a, const HsvIntent(Hsv(120, 1, 1))));
    colour().setExcluded(rgb, excluded: true);
    available(b, on: false);
    await run(const Duration(seconds: 3));
    final ChannelColor aOwn = twin(a).scene.color;

    expect(
      await settle(colour().applyPreset(2)),
      const GroupResult(skipped: 1),
      reason: 'only x is ready and driven, and it is not in the preset',
    );
    expect(twin(a).scene.color, aOwn);
    expect(twin(rgb).scene.color, encoded(rgb, blue));
    expect(twin(x).scene.color, encoded(x, blue));
    expect(twin(x).scene.brightness, 60);

    available(b, on: true);
    await run(const Duration(seconds: 20));
    expect(session(b).status.isReady, isTrue);
    expect(twin(b).scene.color, colour().presets[2]!.lights[b]!.colour);
    expect(twin(b).scene.brightness, 200);
    expect(colour().isFollowing(b), isTrue);
  });

  test('presets: 15 slots per group, colour and white apart, rename, '
      'delete, never the timer; removed lights are dropped', () async {
    await build();
    await activate(colour());
    await settle(colour().setBrightness(180));
    await settle(colour().setTimer(600));
    expect(colour().savePreset(0, 'All'), const GroupSaveResult(4, 4));
    expect(colour().presets, hasLength(GroupPresets.slots));
    expect(GroupPresets.slots, 15);
    expect(() => colour().savePreset(15, 'No'), throwsRangeError);
    expect(() => colour().applyPreset(-1), throwsRangeError);
    expect(colour().savePreset(14, 'Last'), const GroupSaveResult(4, 4));

    await activate(white());
    await settle(white().setBrightness(80));
    expect(white().savePreset(0, 'Warm'), const GroupSaveResult(2, 2));
    expect(colour().presets[0]!.name, 'All');
    expect(white().presets[0]!.name, 'Warm');
    expect(white().presets[0]!.lights.keys, unorderedEquals(<String>[cct, w]));
    expect(store.read(GroupPresets.key(GroupKind.colour)), hasLength(15));
    expect(store.read(GroupPresets.key(GroupKind.white)), hasLength(15));
    final String json = jsonEncode(<Object?>[
      store.read(GroupPresets.key(GroupKind.colour)),
      store.read(GroupPresets.key(GroupKind.white)),
    ]);
    expect(json, isNot(contains('timer')));

    // Applying never starts or stops a timer.
    await activate(colour());
    await settle(colour().setTimer(0));
    await settle(colour().applyPreset(0));
    for (final String id in colourDefaults) {
      expect(twin(id).timerActive, isFalse, reason: id);
    }

    colour().renamePreset(0, 'Evening');
    expect(colour().presets[0]!.name, 'Evening');
    white().deletePreset(0);
    expect(white().presets[0], isNull);
    available(cct, on: false);
    available(w, on: false);
    await run(const Duration(seconds: 3));
    expect(white().savePreset(3, 'Nothing'), const GroupSaveResult(0, 2));
    expect(white().presets[3], isNull, reason: 'no ready light to save');

    // A forgotten light leaves every preset; one left with none is empty.
    await registry.forget(b);
    await _pump();
    expect(colour().presets[0]!.lights.keys, isNot(contains(b)));
    expect(colour().presets[14]!.lights.keys, isNot(contains(b)));
    for (final String id in <String>[rgb, a, x]) {
      await registry.forget(id);
    }
    await _pump();
    expect(colour().presets[0], isNull);
    expect(colour().presets[14], isNull);
    expect(
      GroupPresets.read(store, GroupKind.colour).every((p) => p == null),
      isTrue,
    );
  });

  test('a preset survives the store round trip, pick included', () {
    final GroupPreset p = GroupPreset(
      name: 'Mixed',
      master: 140,
      lights: <String, GroupPresetLight>{
        rgb: GroupPresetLight(
          on: true,
          colour: ChannelColor(ChannelLayout.rgb, const <int>[255, 10, 0]),
          pick: const HsvIntent(Hsv(2.5, 1, 1)),
          mode: 1,
          speed: 5,
          frequency: 5,
        ),
        cct: GroupPresetLight(
          on: false,
          colour: ChannelColor(ChannelLayout.cct, const <int>[40, 200]),
          pick: const WhiteIntent(3000, 1),
          mode: 2,
          speed: 7,
          frequency: 1,
        ),
      },
    );
    final Object? json = jsonDecode(jsonEncode(p.toJson()));
    expect(GroupPreset.fromJson(json), p);
  });

  // ---- effect colours ----------------------------------------------------------------

  test('colour source and beacons reach every colour light that has the '
      'effect and skip the others; a late light catches up; the white group '
      'has none', () async {
    await build(ids: <String>[rgb, a, x, basic, cct, w]);
    available(x, on: false);
    colour().activate();
    await run(const Duration(seconds: 10));
    expect(colour().status.ready, 3);
    const EbColorModeKind police = EbColorModeKind.police;
    expect(
      await settle(colour().setColorMode(police, 0)),
      const GroupResult(ok: 2, skipped: 1),
    );
    expect(
      await settle(colour().setColorMode(EbColorModeKind.firework, 1)),
      const GroupResult(ok: 2, skipped: 1),
    );
    const HsvIntent green = HsvIntent(Hsv(120, 1, 1), white: 0.5);
    const HsvIntent sent = HsvIntent(Hsv(120, 1, 1));
    expect(
      await settle(colour().setPoliceColor(EbPoliceSlot.a, green)),
      const GroupResult(ok: 2, skipped: 1),
    );
    for (final String id in <String>[rgb, a]) {
      expect(twin(id).scene.policeColorMode, 0, reason: id);
      expect(twin(id).scene.fireworkColorMode, 1, reason: id);
      expect(twin(id).scene.policeA, encoded(id, sent), reason: id);
    }
    expect(twin(a).scene.policeA.values, <int>[0, 255, 0, 0]);
    expect(twin(basic).scene.policeColorMode, 1, reason: 'skipped');
    expect(twin(basic).scene.policeA.values, <int>[255, 165, 0]);
    expect(colour().look.policeColorMode, const Common<int>.of(0));
    expect(colour().look.policeA, const Common<Rgb>.of((0, 255, 0)));

    available(x, on: true);
    await run(const Duration(seconds: 20));
    expect(session(x).status.isReady, isTrue);
    expect(twin(x).scene.policeColorMode, 0);
    expect(twin(x).scene.fireworkColorMode, 1);
    expect(twin(x).scene.policeA.values, <int>[0, 255, 0, 0, 0]);

    // The white group has no colour sources or beacons.
    final ChannelColor cctBeacon = twin(cct).scene.policeA;
    expect(await settle(white().setColorMode(police, 0)), const GroupResult());
    expect(
      await settle(white().setPoliceColor(EbPoliceSlot.a, green)),
      const GroupResult(),
    );
    expect(twin(cct).scene.policeA, cctBeacon);
    expect(white().look.policeColorMode, const Common<int>.none());
  });

  test('lights that differ read as mixed until the first change sets them '
      'all', () async {
    await build();
    await activate(colour());
    const EbColorModeKind police = EbColorModeKind.police;
    await settle(colour().setColorMode(police, 1));
    unawaited(session(a).setColorMode(police, 0, origin: CommandOrigin.system));
    unawaited(
      session(a).setPoliceColor(
        EbPoliceSlot.a,
        ChannelColor(ChannelLayout.rgbw, const <int>[0, 0, 255, 0]),
        origin: CommandOrigin.system,
      ),
    );
    await run(const Duration(seconds: 2));
    expect(colour().look.policeColorMode, const Common<int>.mixed());
    expect(colour().look.policeA, const Common<Rgb>.mixed());
    await settle(colour().setColorMode(police, 0));
    await settle(
      colour().setPoliceColor(EbPoliceSlot.a, const HsvIntent(Hsv(0, 1, 1))),
    );
    expect(colour().look.policeColorMode, const Common<int>.of(0));
    expect(colour().look.policeA, const Common<Rgb>.of((255, 0, 0)));
  });

  test('presets keep and restore colour sources and beacons (colour group '
      'only)', () async {
    await build();
    await activate(colour());
    await settle(colour().setBrightness(200));
    await settle(colour().setColorMode(EbColorModeKind.police, 0));
    await settle(colour().setColorMode(EbColorModeKind.club, 1));
    await settle(
      colour().setPoliceColor(EbPoliceSlot.b, const HsvIntent(Hsv(240, 1, 1))),
    );
    expect(colour().savePreset(0, 'Beacons'), const GroupSaveResult(4, 4));
    final GroupPresetLight kept = colour().presets[0]!.lights[a]!;
    expect(kept.colorMode(EbColorModeKind.police), 0);
    expect(kept.colorMode(EbColorModeKind.club), 1);
    expect(kept.policeB!.values, <int>[0, 0, 255, 0]);

    await settle(colour().setColorMode(EbColorModeKind.police, 1));
    await settle(colour().setColorMode(EbColorModeKind.club, 0));
    await settle(
      colour().setPoliceColor(EbPoliceSlot.b, const HsvIntent(Hsv(0, 1, 1))),
    );
    await settle(colour().applyPreset(0));
    for (final String id in colourDefaults) {
      expect(twin(id).scene.policeColorMode, 0, reason: id);
      expect(twin(id).scene.clubColorMode, 1, reason: id);
      expect(
        twin(id).scene.policeB,
        encoded(id, const HsvIntent(Hsv(240, 1, 1))),
        reason: id,
      );
    }
    // A white preset keeps none of them.
    await activate(white());
    await settle(white().setBrightness(90));
    expect(white().savePreset(0, 'Warm'), const GroupSaveResult(2, 2));
    for (final GroupPresetLight l in white().presets[0]!.lights.values) {
      expect(l.colorModes, isNull);
      expect(l.policeA, isNull);
    }
  });

  test(
    'a beacon changed on a following light\'s own screen detaches it',
    () async {
      await build();
      await activate(colour());
      await settle(colour().setBrightness(150));
      expect(colour().isFollowing(a), isTrue);
      unawaited(
        session(a).setPoliceColor(
          EbPoliceSlot.a,
          ChannelColor(ChannelLayout.rgbw, const <int>[0, 0, 255, 0]),
        ),
      );
      await run(const Duration(seconds: 1));
      expect(colour().isOwn(a), isTrue);
      // Group changes to the beacons don't.
      await settle(
        colour().setPoliceColor(EbPoliceSlot.a, const HsvIntent(Hsv(60, 1, 1))),
      );
      expect(colour().isOwn(b), isFalse);
    },
  );

  // ---- identify ----------------------------------------------------------------------

  test('identify blinks exactly twice, about 150 ms on and 150 ms off, then '
      'restores the look', () async {
    await build(ids: <String>[rgb, a]);
    final Want want = manager.want(rgb, WantReason.screen);
    await run(const Duration(seconds: 10));
    session(rgb).setBrightness(120, origin: CommandOrigin.system);
    await run(const Duration(seconds: 1));
    expect(twin(rgb).scene.brightness, 120);

    final Future<void> done = session(rgb).identify();
    final List<int> samples = <int>[];
    const Duration step = Duration(milliseconds: 5);
    for (int i = 0; i < 400; i++) {
      await _pump(5);
      clock.advance(step);
      samples.add(twin(rgb).scene.brightness);
    }
    await done;
    await run(const Duration(seconds: 1));
    // Runs of equal samples: 255 (on) and 0 (off).
    final List<(int, int)> runs = <(int, int)>[];
    for (final int v in samples) {
      if (runs.isNotEmpty && runs.last.$1 == v) {
        runs.last = (v, runs.last.$2 + 1);
      } else {
        runs.add((v, 1));
      }
    }
    final List<int> on = <int>[
      for (final (int v, int n) in runs)
        if (v == 255) n * 5,
    ];
    final List<int> off = <int>[
      for (int i = 1; i < runs.length - 1; i++)
        if (runs[i].$1 == 0 && runs[i - 1].$1 == 255) runs[i].$2 * 5,
    ];
    expect(on, hasLength(FixtureRituals.identifyFlashes));
    expect(FixtureRituals.identifyFlashes, 2);
    for (final int ms in <int>[...on, ...off]) {
      expect(ms, inInclusiveRange(120, 180), reason: '$runs');
    }
    expect(twin(rgb).scene.brightness, 120);
    expect(twin(rgb).sleeping, isFalse);

    // Asleep: woken for the show, asleep again after.
    await session(rgb).setPower(on: false, origin: CommandOrigin.system);
    await run(const Duration(seconds: 1));
    final Future<void> again = session(rgb).identify();
    await run(const Duration(seconds: 2));
    await again;
    await run(const Duration(seconds: 1));
    expect(twin(rgb).sleeping, isTrue);
    expect(twin(rgb).scene.brightness, 120);
    want.release();
  });
}
