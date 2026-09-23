import 'dart:async';
import '../ble/ble_constants.dart';

/// Lease-lock manager to prevent local echo / rubberbanding while the user drags controls.
class EchoSuppressor {
  final Set<String> _heldLocks = {};
  final Map<String, Timer> _releaseTimers = {};
  static const _maxHoldDuration = Duration(seconds: 15);

  /// Acquires a lock while active touch is held.
  void acquireLock(String key) {
    _releaseTimers[key]?.cancel();
    _releaseTimers.remove(key);
    _heldLocks.add(key);
    _releaseTimers[key] = Timer(_maxHoldDuration, () {
      _heldLocks.remove(key);
      _releaseTimers.remove(key);
    });
  }

  /// Releases the active lock and enters a settling grace window.
  void releaseLock(String key) {
    _heldLocks.remove(key);
    _releaseTimers[key]?.cancel();
    _releaseTimers[key] = Timer(
      const Duration(milliseconds: BleConstants.echoSuppressionGraceMs),
      () {
        _releaseTimers.remove(key);
      },
    );
  }

  /// Suppresses external updates for [key] for a fixed [duration]. Used for
  /// discrete toggles (power, sound) which have no "release" gesture.
  void suppressFor(String key, Duration duration) {
    _releaseTimers[key]?.cancel();
    _heldLocks.remove(key);
    _releaseTimers[key] = Timer(duration, () {
      _releaseTimers.remove(key);
    });
  }

  /// Checks if an external update should be suppressed.
  bool isLocked(String key) {
    return _heldLocks.contains(key) || _releaseTimers.containsKey(key);
  }

  /// Releases all locks immediately so external updates apply without suppression.
  void releaseAll() {
    for (final timer in _releaseTimers.values) {
      timer.cancel();
    }
    _releaseTimers.clear();
    _heldLocks.clear();
  }

  void dispose() {
    for (final timer in _releaseTimers.values) {
      timer.cancel();
    }
    _releaseTimers.clear();
    _heldLocks.clear();
  }
}
