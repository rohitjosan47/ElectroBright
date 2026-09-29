// Identify and channel test against the real firmware core: every LED is lit
// on its own, then the light's look is restored exactly — also when the link
// drops half-way and comes back.
@Tags(<String>['fwsim'])
library;

import 'dart:async';
import 'dart:convert';

import 'package:electrobright/core/model/channel_color.dart';
import 'package:electrobright/core/model/fixture.dart';
import 'package:electrobright/core/protocol/eb/eb_fixture_catalog.dart';
import 'package:electrobright/core/util/scheduler.dart';
import 'package:electrobright/sessions/fixture_session.dart';
import 'package:electrobright/sessions/rituals.dart';
import 'package:flutter/foundation.dart';
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

  /// Completes [f] like [run], sampling the light's colour every 5 ms: the
  /// result, and each distinct colour in order with how long it was shown.
  Future<(T, List<_Shown>)> runTracing<T>(Future<T> f) async {
    bool done = false;
    late T value;
    Object? error;
    StackTrace? stack;
    unawaited(
      f.then(
        (T v) {
          value = v;
          done = true;
        },
        onError: (Object e, StackTrace s) {
          error = e;
          stack = s;
          done = true;
        },
      ),
    );
    final List<_Shown> shown = <_Shown>[];
    Future<void> sample() async {
      await pump();
      final List<int> c = await colour();
      if (shown.isNotEmpty && listEquals(shown.last.colour, c)) {
        shown.last.held += const Duration(milliseconds: 5);
      } else {
        shown.add(_Shown(c));
      }
      await link.advance(const Duration(milliseconds: 5));
    }

    for (int i = 0; i < 20000 && !done; i++) {
      await sample();
    }
    expect(done, isTrue, reason: 'did not finish');
    if (error != null) Error.throwWithStackTrace(error!, stack!);
    // The restore frame goes out last: give the light time to apply it.
    for (int i = 0; i < 60; i++) {
      await sample();
    }
    return (value, shown);
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

/// One colour the light showed during a traced run, and for how long.
final class _Shown {
  _Shown(this.colour);
  final List<int> colour;
  Duration held = Duration.zero;

  @override
  String toString() => '$colour for ${held.inMilliseconds} ms';
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
        final Future<bool> t = r.session.channelTest(
          step: const Duration(milliseconds: 400),
          onChannel: reported.add,
        );
        for (int i = 0; i < n; i++) {
          // Mid-step: only LED i is on, at full.
          await r.wait(const Duration(milliseconds: 250));
          seen.add(await r.colour());
          await r.wait(const Duration(milliseconds: 150));
        }
        expect(await r.run(t), isTrue);
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

    // The colour lane is latest-wins and never repeats a frame the stack
    // dropped, so every LED's frame is confirmed before its time starts. A
    // refused write costs a retry, never the LED's turn: each LED is still
    // shown alone for its whole step, in order, and the look comes back.
    Future<void> expectEveryLedInTurn(
      _Rig r,
      List<_Shown> shown,
      List<int?> reported,
    ) async {
      final List<List<int>> leds = <List<int>>[
        for (int i = 0; i < n; i++)
          <int>[for (int c = 0; c < n; c++) c == i ? 255 : 0],
      ];
      // The previous look may or may not be sampled before the first LED.
      final List<_Shown> steps = listEquals(shown.first.colour, look)
          ? shown.sublist(1)
          : shown;
      expect(steps.map((_Shown s) => s.colour).toList(), <List<int>>[
        ...leds,
        look,
      ], reason: '$shown');
      for (final _Shown s in steps.sublist(0, n)) {
        expect(
          s.held,
          greaterThanOrEqualTo(const Duration(milliseconds: 380)),
          reason: '$shown',
        );
      }
      expect(reported, <int?>[for (int i = 0; i < n; i++) i, null]);
      final Map<String, Object?> after = await r.scene();
      expect(after['color'], look);
      expect(after['brightness'], 150);
    }

    test('$name channel test: the first LED\'s frame refused by the stack '
        'is sent again; no LED loses its turn', () async {
      final _Rig r = await _Rig.start(fixture);
      try {
        await setUp(r);
        // Solid already, so the first write of the test is LED 0's frame.
        await r.run(r.session.setMode(1));
        await r.wait(const Duration(milliseconds: 300));
        final List<int?> reported = <int?>[];
        r.link.refuseNextWrites = 1;
        final (bool complete, List<_Shown> shown) = await r.runTracing(
          r.session.channelTest(
            step: const Duration(milliseconds: 400),
            onChannel: reported.add,
          ),
        );
        expect(complete, isTrue);
        expect(r.link.refuseNextWrites, 0);
        await expectEveryLedInTurn(r, shown, reported);
      } finally {
        await r.close();
      }
    });

    if (n > 1) {
      test('$name channel test: the last LED\'s frame refused by the stack '
          'is sent again; the last LED still gets its whole step', () async {
        final _Rig r = await _Rig.start(fixture);
        try {
          await setUp(r);
          final List<int?> reported = <int?>[];
          final (bool complete, List<_Shown> shown) = await r.runTracing(
            r.session.channelTest(
              step: const Duration(milliseconds: 400),
              onChannel: (int? c) {
                reported.add(c);
                // Nothing else is written during a step: the next write
                // is the last LED's frame.
                if (c == n - 2) r.link.refuseNextWrites = 1;
              },
            ),
          );
          expect(complete, isTrue);
          expect(r.link.refuseNextWrites, 0);
          await expectEveryLedInTurn(r, shown, reported);
          expect((await r.scene())['mode'], 11);
        } finally {
          await r.close();
        }
      });
    }

    test('$name channel test restores after the link drops half-way', () async {
      final _Rig r = await _Rig.start(fixture);
      try {
        await setUp(r);
        final Future<bool> t = r.session.channelTest(
          step: const Duration(milliseconds: 400),
        );
        await r.wait(const Duration(milliseconds: 250));
        expect(await r.colour(), <int>[255, for (int c = 1; c < n; c++) 0]);
        // Out of range mid-test: the show stops, the light keeps LED 1 lit.
        await r.link.drop();
        await r.session.linkClosed();
        r.session.setPhase(LinkPhase.waiting);
        await r.wait(const Duration(milliseconds: 500));
        // A single LED had already had its whole turn before the drop.
        expect(await t, n == 1);
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

    test(
      '$name identify sends IDENTIFY alone; the light keeps its state',
      () async {
        final _Rig r = await _Rig.start(fixture);
        try {
          await setUp(r);
          await r.run(r.session.setPower(on: false));
          await r.wait(const Duration(milliseconds: 500));
          await r.link.sounds();
          final int from = r.link.written.length;
          await r.run(r.session.identify());
          await r.wait(const Duration(milliseconds: 800));
          expect(
            <String>[
              for (final Uint8List w in r.link.written.skip(from))
                utf8.decode(w),
            ],
            <String>['IDENTIFY\n'],
          );
          final Map<String, Object?> after = await r.link.deviceState();
          expect((after['scene']! as Map<String, Object?>)['brightness'], 150);
          expect(after['sleeping'], 1);
          expect(await r.link.sounds(), <String>['Identify']);
        } finally {
          await r.close();
        }
      },
    );
  }
}
