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

  Future<void> _wait(Duration d) {
    final Completer<void> done = Completer<void>();
    scheduler.after(d, done.complete);
    return done.future;
  }

  bool _live(EbSession s) =>
      identical(session, s) &&
      s.phase != EbPhase.closed &&
      status.phase == LinkPhase.ready;

  /// Blinks the light three times, then restores its look (and sleep).
  Future<void> identify() async {
    final EbSession? s = session;
    if (s == null || !_live(s)) return;
    final int brightness = s.view.state.scene.brightness;
    final bool wasAsleep = s.view.state.sleeping;
    // Frames never wake a sleeping light: wake it for the show.
    if (wasAsleep) await s.setPower(on: true);
    s.beginGesture(EbKeys.brightness);
    try {
      for (int i = 0; i < 3 && _live(s); i++) {
        s.setBrightness(255, live: true);
        await _wait(const Duration(milliseconds: 260));
        if (!_live(s)) break;
        s.setBrightness(0, live: true);
        await _wait(const Duration(milliseconds: 220));
      }
    } finally {
      if (identical(session, s)) s.endGesture(EbKeys.brightness);
      setLook(
        brightness: brightness > 0 ? brightness : 255,
        keepOffline: restoreWindow,
      );
      if (wasAsleep) {
        unawaited(setPower(on: false, keepOffline: restoreWindow));
      }
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
      );
      if (before.mode != EbModeCatalog.solid) {
        unawaited(setMode(before.mode, keepOffline: restoreWindow));
      }
      if (wasAsleep) {
        unawaited(setPower(on: false, keepOffline: restoreWindow));
      }
    }
  }
}
