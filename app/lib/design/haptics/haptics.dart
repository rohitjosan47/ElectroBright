import 'dart:async';

import 'package:flutter/services.dart';

import '../platform/platform_api.g.dart';

export '../platform/platform_api.g.dart' show HapticEvent;

enum HapticsLevel { off, subtle, full }

/// Semantic haptics (see the plan's haptics table). Rate-limited so fast
/// drags never queue a buzz storm; falls back to Flutter's HapticFeedback
/// when the native host is unavailable.
final class Haptics {
  Haptics({HapticsHostApi? api, Duration Function()? clock})
    : _api = api ?? HapticsHostApi(),
      _clock = clock ?? _stopwatchClock;

  final HapticsHostApi _api;
  final Duration Function() _clock;
  HapticsLevel level = HapticsLevel.full;

  static const Duration minGap = Duration(milliseconds: 35);
  Duration? _last;

  static final Stopwatch _watch = Stopwatch()..start();
  static Duration _stopwatchClock() => _watch.elapsed;

  double get _scale => switch (level) {
    HapticsLevel.off => 0,
    HapticsLevel.subtle => 0.6,
    HapticsLevel.full => 1,
  };

  /// Warm up for an imminent gesture (touch-down).
  void prepare(HapticEvent event) {
    if (level == HapticsLevel.off) return;
    unawaited(_api.prepare(event).catchError((Object _) {}));
  }

  /// Plays [event] unless one played less than [minGap] ago.
  bool play(HapticEvent event, {double intensity = 1}) {
    if (level == HapticsLevel.off) return false;
    final Duration now = _clock();
    final Duration? last = _last;
    if (last != null && now - last < minGap) return false;
    _last = now;
    unawaited(
      _api
          .play(event, (intensity * _scale).clamp(0.0, 1.0))
          .catchError((Object _) => _fallback(event)),
    );
    return true;
  }

  Future<void> _fallback(HapticEvent e) => switch (e) {
    HapticEvent.selection ||
    HapticEvent.detent ||
    HapticEvent.hueDetent => HapticFeedback.selectionClick(),
    HapticEvent.edge ||
    HapticEvent.hueDetentStrong ||
    HapticEvent.powerOff => HapticFeedback.lightImpact(),
    HapticEvent.powerOn ||
    HapticEvent.longPress ||
    HapticEvent.success ||
    HapticEvent.presetLoaded ||
    HapticEvent.connected => HapticFeedback.mediumImpact(),
    HapticEvent.warning || HapticEvent.error => HapticFeedback.heavyImpact(),
  };
}
