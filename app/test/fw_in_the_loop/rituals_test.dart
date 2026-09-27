// Identify and channel test against the real firmware core: every LED is lit
// on its own, then the light's look is restored exactly — also when the link
// drops half-way and comes back.
@Tags(<String>['fwsim'])
library;

import 'dart:async';

import 'package:electrobright/core/model/channel_color.dart';
import 'package:electrobright/core/model/fixture.dart';
import 'package:electrobright/core/protocol/eb/eb_fixture_catalog.dart';
import 'package:electrobright/core/util/scheduler.dart';
import 'package:electrobright/sessions/fixture_session.dart';
import 'package:electrobright/sessions/rituals.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fixtures.dart';
import '../support/fwsim/fwsim_link.dart';
import '../support/fwsim/fwsim_process.dart';

final class _Rig {
  _Rig(this.fixture, this.sim, this.scheduler, this.session);
  final EbFixtureSpec fixture;
  final FwSim sim;
  final ManualScheduler scheduler;
  final FixtureSession session;
  late FwSimLink link;

  static Future<_Rig> start(EbFixtureSpec fixture) async {
    final FwSim sim = await FwSim.start(fixture: fixture.fwsimName);
    final ManualScheduler scheduler = ManualScheduler();
    final FixtureSession session = FixtureSession(
      Fixture(
        id: 'f',
        deviceId: 'd',
        name: 'Test',
        layout: fixture.layout,
        driver: DriverKind.electroBright,
        addedAt: DateTime(2026),
      ),
      scheduler: scheduler,
    );
    final _Rig r = _Rig(fixture, sim, scheduler, session);
    await r.connect();
    return r;
  }

  /// A fresh link to the same light, then the session's handshake.
  Future<void> connect() async {
    link = await FwSimLink.connect(sim, scheduler);
    session.setPhase(LinkPhase.connecting);
    await run(session.attach(link));
  }

  /// Completes [f] while moving app and light time forward.
  Future<T> run<T>(Future<T> f) async {
    bool done = false;
    late T value;
    unawaited(
      f.then((T v) {
        value = v;
        done = true;
      }),
    );
    for (int i = 0; i < 20000 && !done; i++) {
      await pump();
      await link.advance(const Duration(milliseconds: 5));
    }
    expect(done, isTrue, reason: 'did not finish');
    return value;
  }

  Future<void> wait(Duration d) => link.advance(d);

  Future<Map<String, Object?>> scene() async =>
      (await link.deviceState())['scene']! as Map<String, Object?>;

  Future<List<int>> colour() async =>
      ((await scene())['color']! as List<Object?>).cast<int>();

  Future<void> close() async {
    await session.dispose();
    await sim.close();
  }
}

void main() {
  for (final EbFixtureSpec fixture in fixturesUnderTest()) {
    final String name = fixture.layout.wire;
    final int n = fixture.layout.n;
    // A look that is not the factory one, in Fire (mode 11).
    final List<int> look = <int>[for (int i = 0; i < n; i++) 40 + 30 * i];

    Future<void> setUp(_Rig r) async {
      r.session.setLook(
        color: ChannelColor(fixture.layout, look),
        brightness: 150,
      );
      await r.run(r.session.setMode(11));
      await r.wait(const Duration(milliseconds: 300));
      expect(await r.colour(), look);
    }

    test('$name channel test lights each LED alone, then restores', () async {
      final _Rig r = await _Rig.start(fixture);
      try {
        await setUp(r);
        final List<List<int>> seen = <List<int>>[];
        final List<int?> reported = <int?>[];
        final Future<void> t = r.session.channelTest(
          step: const Duration(milliseconds: 400),
          onChannel: reported.add,
        );
        for (int i = 0; i < n; i++) {
          // Mid-step: only LED i is on, at full.
          await r.wait(const Duration(milliseconds: 250));
          seen.add(await r.colour());
          await r.wait(const Duration(milliseconds: 150));
        }
        await r.run(t);
        await r.wait(const Duration(milliseconds: 500));
        expect(seen, <List<int>>[
          for (int i = 0; i < n; i++)
            <int>[for (int c = 0; c < n; c++) c == i ? 255 : 0],
        ]);
        expect(reported, <int?>[for (int i = 0; i < n; i++) i, null]);
        final Map<String, Object?> after = await r.scene();
        expect(after['color'], look);
        expect(after['brightness'], 150);
        expect(after['mode'], 11);
      } finally {
        await r.close();
      }
    });

    test('$name channel test restores after the link drops half-way', () async {
      final _Rig r = await _Rig.start(fixture);
      try {
        await setUp(r);
        final Future<void> t = r.session.channelTest(
          step: const Duration(milliseconds: 400),
        );
        await r.wait(const Duration(milliseconds: 250));
        expect(await r.colour(), <int>[255, for (int c = 1; c < n; c++) 0]);
        // Out of range mid-test: the show stops, the light keeps LED 1 lit.
        await r.link.drop();
        await r.session.linkClosed();
        r.session.setPhase(LinkPhase.waiting);
        await r.wait(const Duration(milliseconds: 500));
        await t;
        // Back within the restore window: the look comes back exactly.
        await r.wait(const Duration(seconds: 20));
        await r.connect();
        await r.wait(const Duration(seconds: 1));
        final Map<String, Object?> after = await r.scene();
        expect(after['color'], look);
        expect(after['brightness'], 150);
        expect(after['mode'], 11);
      } finally {
        await r.close();
      }
    });

    test('$name identify blinks and restores brightness and sleep', () async {
      final _Rig r = await _Rig.start(fixture);
      try {
        await setUp(r);
        await r.run(r.session.setPower(on: false));
        final Future<void> t = r.session.identify();
        // Mid first flash (150 ms on).
        await r.wait(const Duration(milliseconds: 75));
        final Map<String, Object?> lit = await r.link.deviceState();
        expect(lit['sleeping'], 0, reason: 'woken for the show');
        expect((lit['scene']! as Map<String, Object?>)['brightness'], 255);
        await r.run(t);
        await r.wait(const Duration(milliseconds: 500));
        final Map<String, Object?> after = await r.link.deviceState();
        expect((after['scene']! as Map<String, Object?>)['brightness'], 150);
        expect(after['sleeping'], 1);
      } finally {
        await r.close();
      }
    });
  }
}
