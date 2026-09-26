import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';

/// Asks for the display's highest refresh rate only while it is needed: a
/// finger is down, or frames come faster than a glyph's 30 Hz steps
/// (something moves at the display rate: a spring, a glide, a scroll). Idle
/// for [release], it lets the system choose (and lower) the rate again.
/// Android only; iOS adapts on its own.
final class RefreshGovernor {
  RefreshGovernor(this._send);

  /// Sends the wish to the platform.
  final void Function(bool high) _send;

  /// Frames this close are motion at the display rate (at least 60 Hz:
  /// 16.7 ms apart). A 30 Hz glyph steps 33 ms apart (up to 42 ms on a
  /// 120 Hz display).
  static const Duration dense = Duration(milliseconds: 18);

  /// Consecutive close frames that make motion: glyphs stepping on separate
  /// 30 Hz clocks interleave (their gaps add up to a step, so one of any two
  /// is over 20 ms), never this.
  static const int run = 3;

  /// How long after the last finger or dense frame the wish is dropped.
  static const Duration release = Duration(milliseconds: 400);

  bool _high = false;
  bool _started = false;
  int _pointers = 0;
  Duration? _lastFrame;
  int _close = 0;
  Timer? _idle;

  bool get high => _high;

  void start() {
    if (_started) return;
    _started = true;
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointer);
    SchedulerBinding.instance.addPersistentFrameCallback(_onFrame);
  }

  /// Stops listening (persistent frame callbacks can't be removed; they go
  /// quiet).
  void stop() {
    if (!_started) return;
    _started = false;
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_onPointer);
    _idle?.cancel();
    _set(false);
  }

  void _onPointer(PointerEvent e) {
    if (!_started) return;
    if (e is PointerDownEvent) {
      _pointers++;
      _wake();
    } else if (e is PointerUpEvent || e is PointerCancelEvent) {
      if (_pointers > 0) _pointers--;
      _wake();
    }
  }

  void _onFrame(Duration timeStamp) {
    if (!_started) return;
    final Duration? last = _lastFrame;
    _lastFrame = timeStamp;
    _close = last != null && timeStamp - last <= dense ? _close + 1 : 0;
    if (_close >= run) _wake();
  }

  void _wake() {
    _set(true);
    _idle?.cancel();
    _idle = Timer(release, () {
      if (_pointers > 0) return _wake();
      _set(false);
    });
  }

  void _set(bool high) {
    if (high == _high) return;
    _high = high;
    _send(high);
  }
}
