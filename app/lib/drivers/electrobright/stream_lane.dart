import 'dart:async';

import '../../core/ble/ble_link.dart';
import '../../core/ble/link_writer.dart';
import '../../core/model/channel_color.dart';
import '../../core/protocol/eb/eb_frame.dart';
import '../../core/util/scheduler.dart';

typedef StreamValue = ({ChannelColor color, int brightness});

/// Colour and master brightness as binary frames. The firmware keeps only the
/// newest frame (a one-deep mailbox), so this lane is latest-wins: a frame is
/// built from the session's *desired* state at the moment it is written and
/// only one write is outstanding. It never repeats a stale cache.
///
/// Frames are written without response while a finger moves; the frame after
/// release (and an automatic one after [idleFlush] of quiet) is written with
/// response, so the final colour cannot be lost even when the platform drops
/// fast writes (iOS has no flow control for them in the BLE plugin).
final class StreamLane {
  StreamLane({
    required this._writer,
    required this._rx,
    required this._scheduler,
    required this._desired,
    required this._onDelivered,
    this.minGap = const Duration(milliseconds: 25),
    this.idleFlush = const Duration(milliseconds: 120),
  });

  final LinkWriter _writer;
  final GattRef _rx;
  final Scheduler _scheduler;
  final StreamValue Function() _desired;
  final void Function(StreamValue delivered) _onDelivered;

  /// Minimum spacing between frames (~40 Hz on iOS; the firmware smooths
  /// colour over 45 ms, so this is visually continuous).
  final Duration minGap;
  final Duration idleFlush;

  int _seq = 0;
  bool _dirty = false;
  bool _terminal = false;
  int _unfenced = 0;
  bool _inFlight = false;
  int _holds = 0;
  bool _closed = false;
  Duration? _lastWrite;
  Cancelable? _gapTimer;
  Cancelable? _idleTimer;
  final List<Completer<void>> _fenceWaiters = <Completer<void>>[];

  int framesWritten = 0;
  int reliableFrames = 0;

  /// Nothing waiting, nothing in flight, everything written reliably.
  bool get isIdle => !_dirty && !_inFlight && _unfenced == 0;

  /// The desired value changed; send it (reliably when [terminal]).
  void submit({bool terminal = false}) {
    if (_closed) return;
    _dirty = true;
    _terminal = _terminal || terminal;
    _idleTimer?.cancel();
    _idleTimer = null;
    _pump();
  }

  /// Makes sure the latest desired value reached the light reliably, then
  /// blocks further frames (a hold) before completing. The caller must
  /// [release] after its text command was answered. Taking the hold at the
  /// completion point (not after an await) guarantees no frame slips in
  /// between.
  Future<void> fenceAndHold() {
    if (_closed) {
      return Future<void>.error(
        const LinkClosedException(LinkLossReason.failed),
      );
    }
    if (isIdle && _holds == 0) {
      _holds++;
      return Future<void>.value();
    }
    final Completer<void> c = Completer<void>();
    _fenceWaiters.add(c);
    _dirty = true;
    _terminal = true;
    _pump();
    return c.future;
  }

  void hold() => _holds++;

  void release() {
    if (_holds > 0) _holds--;
    _pump();
  }

  void close() {
    _closed = true;
    _gapTimer?.cancel();
    _idleTimer?.cancel();
    for (final Completer<void> c in _fenceWaiters) {
      c.completeError(const LinkClosedException(LinkLossReason.failed));
    }
    _fenceWaiters.clear();
  }

  void _pump() {
    if (_closed || _inFlight || !_dirty) return;
    // A pending fence may pass its own hold-free frame; other frames wait.
    if (_holds > 0) return;
    final Duration now = _scheduler.now;
    final Duration? last = _lastWrite;
    if (last != null) {
      final Duration wait = last + minGap - now;
      if (wait > Duration.zero) {
        _gapTimer ??= _scheduler.after(wait, () {
          _gapTimer = null;
          _pump();
        });
        return;
      }
    }
    final StreamValue value = _desired();
    final bool reliable = _terminal;
    _dirty = false;
    _terminal = false;
    _inFlight = true;
    final int seq = _seq;
    _seq = (_seq + 1) & 0xFF;
    unawaited(
      _writer
          .write(
            _rx,
            EbFrame.encode(seq, value.color, value.brightness),
            withResponse: reliable,
          )
          .then(
            (_) => _delivered(value, reliable: reliable),
            onError: (Object _) {
              // The link failed; the session tears everything down.
            },
          )
          .whenComplete(() {
            _inFlight = false;
            _lastWrite = _scheduler.now;
            _scheduleIdleFlush();
            _pump();
          }),
    );
  }

  void _delivered(StreamValue value, {required bool reliable}) {
    framesWritten++;
    if (!reliable) {
      _unfenced++;
      return;
    }
    reliableFrames++;
    _unfenced = 0;
    _onDelivered(value);
    if (_fenceWaiters.isEmpty) return;
    if (_dirty) {
      // The value moved while this frame was in flight: fence on the next one.
      _terminal = true;
      return;
    }
    _holds += _fenceWaiters.length;
    for (final Completer<void> c in _fenceWaiters) {
      c.complete();
    }
    _fenceWaiters.clear();
  }

  void _scheduleIdleFlush() {
    if (_closed || _dirty || _unfenced == 0 || _idleTimer != null) return;
    _idleTimer = _scheduler.after(idleFlush, () {
      _idleTimer = null;
      if (!_dirty && _unfenced > 0) submit(terminal: true);
    });
  }
}
