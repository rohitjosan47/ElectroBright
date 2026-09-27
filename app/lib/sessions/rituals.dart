import 'dart:async';

import '../core/model/channel_color.dart';
import '../core/model/channel_layout.dart';
import '../core/protocol/eb/eb_scene.dart';
import '../core/protocol/eb/mode_catalog.dart';
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

  Future<void> _wait(Duration d) {
    final Completer<void> done = Completer<void>();
    scheduler.after(d, done.complete);
    return done.future;
  }

  bool _live(EbSession s) =>
      identical(session, s) &&
      s.phase != EbPhase.closed &&
      status.phase == LinkPhase.ready;

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
  /// LED lit (by wire index), then null when done.
  Future<void> channelTest({
    void Function(int? channel)? onChannel,
    Duration step = const Duration(milliseconds: 1200),
  }) async {
    final EbSession? s = session;
    if (s == null || !_live(s)) return;
    final EbScene before = s.view.state.scene;
    final bool wasAsleep = s.view.state.sleeping;
    final ChannelLayout l = s.layout;
    try {
      if (wasAsleep) await s.setPower(on: true);
      if (before.mode != EbModeCatalog.solid) {
        await s.setMode(EbModeCatalog.solid);
      }
      s.beginGesture(EbKeys.color);
      for (int i = 0; i < l.n && _live(s); i++) {
        onChannel?.call(i);
        s.setLook(
          color: ChannelColor(l, <int>[
            for (int c = 0; c < l.n; c++) c == i ? 255 : 0,
          ]),
          brightness: 255,
          live: true,
        );
        await _wait(step);
      }
    } finally {
      if (identical(session, s)) s.endGesture(EbKeys.color);
      onChannel?.call(null);
      setLook(
        color: before.color,
        brightness: before.brightness,
        keepOffline: restoreWindow,
        origin: CommandOrigin.system,
      );
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
  }
}
