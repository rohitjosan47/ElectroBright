import 'dart:async';

import 'package:electrobright/core/model/channel_color.dart';
import 'package:electrobright/core/protocol/eb/eb_fixture_catalog.dart';
import 'package:electrobright/core/protocol/eb/eb_scene.dart';
import 'package:electrobright/core/util/scheduler.dart';
import 'package:electrobright/drivers/electrobright/eb_session.dart';
import 'package:electrobright/drivers/electrobright/eb_types.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fwsim_link.dart';
import 'fwsim_process.dart';

/// An [EbSession] connected to the real firmware core, on virtual time.
final class EbHarness {
  EbHarness._(this.sim, this.scheduler, this.link, this.session) {
    _eventSub = session.events.listen(events.add);
  }

  /// [fixture]: which firmware fixture fwsim runs (the session learns the
  /// layout in its handshake, starting from the RGBW guess).
  static Future<EbHarness> start({
    EbFixtureSpec fixture = EbFixtureCatalog.rgbw,
    PassTiming timing = PassTiming.immediate,
    int seed = 1,
    int mtu = 247,
    Duration subscribeDelay = Duration.zero,
    bool handshake = true,
    List<String> deviceSetup = const <String>[],
  }) async {
    final FwSim sim = await FwSim.start(fixture: fixture.fwsimName);
    for (final String request in deviceSetup) {
      await sim.request(request);
    }
    final ManualScheduler scheduler = ManualScheduler();
    final FwSimLink link = await FwSimLink.connect(
      sim,
      scheduler,
      timing: timing,
      seed: seed,
      mtu: mtu,
      subscribeDelay: subscribeDelay,
    );
    final EbSession session = EbSession(link: link, scheduler: scheduler);
    final EbHarness h = EbHarness._(sim, scheduler, link, session);
    if (handshake) await h.run(session.start());
    await h.link.sounds(); // drop sounds from the handshake
    return h;
  }

  final FwSim sim;
  final ManualScheduler scheduler;
  final FwSimLink link;
  final EbSession session;
  final List<EbEvent> events = <EbEvent>[];
  late final StreamSubscription<EbEvent> _eventSub;

  EbDeviceState get view => session.view.state;

  /// Completes [future] while advancing virtual time (5 ms steps).
  Future<T> run<T>(
    Future<T> future, {
    Duration limit = const Duration(seconds: 60),
  }) async {
    bool done = false;
    late T value;
    Object? error;
    StackTrace? stack;
    unawaited(
      future.then(
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
    Duration t = Duration.zero;
    while (true) {
      await pump();
      if (done) break;
      if (t > limit) {
        throw TimeoutException('not done after $limit of virtual time');
      }
      await link.advance(const Duration(milliseconds: 5));
      t += const Duration(milliseconds: 5);
    }
    if (error != null) Error.throwWithStackTrace(error!, stack!);
    return value;
  }

  /// Advances time until the app and the light have nothing left to do.
  Future<void> settle({
    Duration limit = const Duration(seconds: 60),
    Duration atLeast = Duration.zero,
  }) async {
    Duration t = Duration.zero;
    while (true) {
      await pump();
      if (t >= atLeast && session.isIdle && link.isQuiet) {
        final Map<String, Object?> st = await link.deviceState();
        if (st['pendingText'] == 0 &&
            st['mailbox'] == 0 &&
            st['pendingReplies'] == 0) {
          await pump();
          if (session.isIdle) return;
        }
      }
      if (t > limit) {
        throw TimeoutException(
          'not settled after $limit: idle=${session.isIdle} '
          'lane=${session.commandLane.isIdle} stream=${session.streamLane.isIdle} '
          'pending=${session.view.pending}',
        );
      }
      await link.advance(const Duration(milliseconds: 5));
      t += const Duration(milliseconds: 5);
    }
  }

  Future<void> wait(Duration d) => link.advance(d);

  /// The light, the session's confirmed state and the app's intent agree.
  Future<void> expectConverged({String reason = ''}) async {
    final Map<String, Object?> device = await link.deviceState();
    final Map<String, Object?> dScene =
        device['scene']! as Map<String, Object?>;
    final EbScene deviceScene = EbScene(
      color: _rgbw(dScene['color']),
      brightness: dScene['brightness']! as int,
      mode: dScene['mode']! as int,
      speeds: (dScene['speed']! as List<Object?>).cast<int>(),
      frequencies: (dScene['freq']! as List<Object?>).cast<int>(),
      fireworkColorMode: dScene['fireworkColorMode']! as int,
      clubColorMode: dScene['clubColorMode']! as int,
      policeColorMode: dScene['policeColorMode']! as int,
      policeA: _rgbw(dScene['policeA']),
      policeB: _rgbw(dScene['policeB']),
    );
    final bool deviceSleeping = device['sleeping'] == 1;
    final bool deviceTimer =
        (device['timer']! as Map<String, Object?>)['active'] == 1;
    final Set<int> devicePresets = (device['presets']! as List<Object?>)
        .cast<int>()
        .toSet();
    final bool deviceSound = device['sound'] == 1;
    for (final (String name, EbDeviceState s) in <(String, EbDeviceState)>[
      ('view', session.view.state),
      ('confirmed', session.confirmed),
    ]) {
      expect(s.scene, deviceScene, reason: '$name scene $reason');
      expect(s.sleeping, deviceSleeping, reason: '$name sleeping $reason');
      expect(
        s.timerDeadline != null,
        deviceTimer,
        reason: '$name timer $reason',
      );
      expect(s.soundOn, deviceSound, reason: '$name sound $reason');
      expect(s.presets, devicePresets, reason: '$name presets $reason');
    }
    expect(session.view.pending, isEmpty, reason: 'pending $reason');
  }

  /// The colour the light holds (its scene, fwsim STATE).
  Future<ChannelColor> deviceColor() async => _rgbw(
    ((await link.deviceState())['scene']! as Map<String, Object?>)['color'],
  );

  /// Firmware counters (fwsim STATE stats).
  Future<Map<String, Object?>> deviceStats() async =>
      (await link.deviceState())['stats']! as Map<String, Object?>;

  Future<void> close() async {
    await _eventSub.cancel();
    await session.dispose();
    await sim.close();
  }

  /// A colour of the device STATE (one value per channel of the light).
  ChannelColor _rgbw(Object? v) =>
      ChannelColor(session.layout, (v! as List<Object?>).cast<int>());
}
