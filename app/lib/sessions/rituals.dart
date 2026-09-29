import 'dart:async';

import '../core/model/channel_color.dart';
import '../core/model/channel_layout.dart';
import '../core/protocol/eb/eb_scene.dart';
import '../core/protocol/eb/mode_catalog.dart';
import '../core/util/scheduler.dart';
import '../drivers/electrobright/eb_session.dart';
import '../drivers/electrobright/eb_types.dart';
import 'fixture_session.dart';

/// Short, self-restoring light shows used to find or check a light. Timed by
/// the session's scheduler; if the link drops half-way the show stops and
/// the restore waits (up to [restoreWindow]) for the light to come back.
extension FixtureRituals on FixtureSession {
  static const Duration restoreWindow = Duration(seconds: 60);

  /// Identify's blinks and their timing (the firmware's own IDENTIFY uses
  /// the same).
  static const int identifyFlashes = 2;
  static const Duration identifyOn = Duration(milliseconds: 150);
  static const Duration identifyOff = Duration(milliseconds: 150);

  /// How long one step of the channel test may wait for the light before
  /// the test gives up. A link that ended or a frame refused three times
  /// fails at once; a write the stack never completes blocks the colour lane
  /// until the link itself times out, so this only frees the test, not the
  /// lane.
  static const Duration deliveryLimit = Duration(seconds: 3);

  Future<void> _wait(Duration d) {
    final Completer<void> done = Completer<void>();
    scheduler.after(d, done.complete);
    return done.future;
  }

  bool _live(EbSession s) =>
      identical(session, s) && s.phase != EbPhase.closed && status.isReady;

  /// Waits until the latest look reached the light reliably. False when the
  /// link ended, the light kept refusing the frame, or nothing came back
  /// within [deliveryLimit] (the wait is abandoned, not the write).
  Future<bool> _delivered(EbSession s) async {
    final Completer<bool> done = Completer<bool>();
    final Cancelable limit = scheduler.after(deliveryLimit, () {
      if (!done.isCompleted) done.complete(false);
    });
    unawaited(
      s.lookDelivered().then(
        (_) {
          if (!done.isCompleted) done.complete(true);
        },
        onError: (Object _) {
          if (!done.isCompleted) done.complete(false);
        },
      ),
    );
    final bool ok = await done.future;
    limit.cancel();
    return ok;
  }

  /// Makes the light show itself. Firmware with IDENTIFY does it alone: two
  /// crisp flashes and a chirp, even asleep, then it restores itself.
  ///
  /// Older firmware dips twice from its level to the lowest one and back
  /// ([identifyOff] low, [identifyOn] at its level), then gets its exact
  /// level again. Never 0 (a release at 0 turns a light off, with its sleep
  /// beep), no power change, no sound: a sleeping light shows nothing.
  Future<void> identify() async {
    final EbSession? s = session;
    if (s == null || !_live(s)) return;
    if (s.view.firmware?.capabilities.supportsIdentify ?? false) {
      await s.identify();
      return;
    }
    final int level = s.view.state.scene.brightness;
    if (s.view.state.sleeping || level <= 0) return;
    s.beginGesture(EbKeys.brightness);
    try {
      for (int i = 0; i < identifyFlashes && _live(s); i++) {
        s.setBrightness(1, live: true);
        await _wait(identifyOff);
        if (!_live(s)) break;
        s.setBrightness(level, live: true);
        await _wait(identifyOn);
      }
    } finally {
      if (identical(session, s)) s.endGesture(EbKeys.brightness);
      setLook(
        brightness: level,
        keepOffline: restoreWindow,
        origin: CommandOrigin.system,
      );
    }
  }

  /// Lights each LED on its own in turn ([step] each), then restores the
  /// light's colour, brightness, mode and sleep. [onChannel] reports the
  /// LED lit (by wire index) once the light confirmed it, then null when
  /// done. Returns whether every LED got its turn: false when the light
  /// stopped answering or the link ended, in which case the test stops
  /// early (and still restores).
  ///
  /// Every step is a reliable frame, confirmed before its time starts: the
  /// colour lane is latest-wins and never repeats a frame the stack dropped,
  /// so a fire-and-forget step could lose its whole turn. The last LED would
  /// then be overwritten by the restore before it was ever seen.
  Future<bool> channelTest({
    void Function(int? channel)? onChannel,
    Duration step = const Duration(milliseconds: 1200),
  }) async {
    final EbSession? s = session;
    if (s == null || !_live(s)) return false;
    final EbScene before = s.view.state.scene;
    final bool wasAsleep = s.view.state.sleeping;
    final ChannelLayout l = s.layout;
    int shown = 0;
    try {
      if (wasAsleep) await s.setPower(on: true);
      if (before.mode != EbModeCatalog.solid) {
        await s.setMode(EbModeCatalog.solid);
      }
      s.beginGesture(EbKeys.color);
      for (int i = 0; i < l.n && _live(s); i++) {
        s.setLook(
          color: ChannelColor(l, <int>[
            for (int c = 0; c < l.n; c++) c == i ? 255 : 0,
          ]),
          brightness: 255,
        );
        if (!await _delivered(s)) break;
        onChannel?.call(i);
        await _wait(step);
        shown++;
      }
    } finally {
      onChannel?.call(null);
      // The restore goes out first; ending the gesture afterwards only
      // repeats it reliably (every step was fenced, nothing else is left).
      setLook(
        color: before.color,
        brightness: before.brightness,
        keepOffline: restoreWindow,
        origin: CommandOrigin.system,
      );
      if (identical(session, s)) s.endGesture(EbKeys.color);
      if (before.mode != EbModeCatalog.solid) {
        unawaited(
          setMode(
            before.mode,
            keepOffline: restoreWindow,
            origin: CommandOrigin.system,
          ),
        );
      }
      if (wasAsleep) {
        unawaited(
          setPower(
            on: false,
            keepOffline: restoreWindow,
            origin: CommandOrigin.system,
          ),
        );
      }
    }
    return shown == l.n;
  }
}
