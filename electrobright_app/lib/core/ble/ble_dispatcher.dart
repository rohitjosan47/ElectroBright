import 'dart:async';
import 'dart:collection';
import 'ble_constants.dart';
import 'ble_transport.dart';

/// Command priority classification.
enum CommandPriority {
  immediate,   // High priority (Mode change, Power, Preset, Settings)
  continuous,  // Low priority, high frequency (Sliders: Brightness, RGBW, Speed, Freq)
}

abstract class _DispatcherItem {
  bool continuous = false;

  /// Returns true when the transport accepted the write.
  Future<bool> execute(BleTransport transport);
}

class _StringItem extends _DispatcherItem {
  final String command;
  _StringItem(this.command);

  @override
  Future<bool> execute(BleTransport transport) {
    return transport.sendRaw(command).timeout(const Duration(seconds: 5));
  }
}

class _BinaryItem extends _DispatcherItem {
  final List<int> bytes;
  final bool withoutResponse;
  _BinaryItem(this.bytes, {this.withoutResponse = true});

  @override
  Future<bool> execute(BleTransport transport) {
    return transport.sendBytes(bytes, withoutResponse: withoutResponse).timeout(const Duration(seconds: 5));
  }
}

/// Smart BLE Command Dispatcher featuring:
/// 1. Coalescing Throttle: continuous items are sent at most once every
///    [BleConstants.continuousThrottleMs]; only the latest value per identity is kept.
/// 2. Stream Deduplication: Redundant intermediate values are replaced in-flight.
/// 3. Guaranteed Terminal Dispatch: Final touch release is guaranteed to send immediately.
/// 4. Binary Fast-Path Support: Seamlessly routes raw byte streams for high-speed color updates.
class BleDispatcher {
  final BleTransport _transport;
  final Map<String, _DispatcherItem> _pendingMap = {};
  bool _isSending = false;
  bool _disposed = false;
  final Queue<_DispatcherItem> _queue = Queue();
  final Stopwatch _sinceContinuousSend = Stopwatch();
  int _failureCount = 0;

  BleDispatcher(this._transport);

  /// Number of writes the transport rejected or that timed out.
  int get failureCount => _failureCount;

  /// Dispatches an ASCII command with priority-aware throttling.
  void dispatch(String command, {CommandPriority priority = CommandPriority.immediate, String identity = 'cmd'}) {
    if (priority == CommandPriority.immediate) {
      // Flush any pending continuous first, then execute immediate
      flushPending();
      _enqueue(_StringItem(command));
      return;
    }

    // Continuous priority (e.g., slider drag)
    _pendingMap[identity] = _StringItem(command)..continuous = true;
    _drain();
  }

  /// Dispatches a raw binary packet (e.g. fast-path color streaming) with priority-aware throttling.
  void dispatchBinary(List<int> bytes, {CommandPriority priority = CommandPriority.continuous, String identity = 'color'}) {
    if (priority == CommandPriority.immediate) {
      // Terminal value (e.g. finger lifted): drop the now-stale in-flight drag
      // value for this identity and send the final one with a write response
      // so it cannot be silently lost.
      _pendingMap.remove(identity);
      flushPending();
      _enqueue(_BinaryItem(bytes, withoutResponse: false));
      return;
    }

    // Continuous priority (e.g., color wheel drag)
    _pendingMap[identity] = _BinaryItem(bytes)..continuous = true;
    _drain();
  }

  /// Forces any in-flight throttled command to be sent immediately (e.g., on pointer up).
  void flushPending() {
    for (final item in _pendingMap.values) {
      _queue.add(item);
    }
    _pendingMap.clear();
    _drain();
  }

  void _enqueue(_DispatcherItem item) {
    _queue.add(item);
    _drain();
  }

  Future<void> _drain() async {
    if (_isSending || _disposed) return;
    _isSending = true;
    try {
      while (!_disposed && (_queue.isNotEmpty || _pendingMap.isNotEmpty)) {
        _DispatcherItem? item;
        if (_queue.isNotEmpty) {
          item = _queue.removeFirst();
        } else {
          // Throttle continuous traffic. While waiting, newer values replace
          // the pending one, and immediate items can still jump ahead.
          final waitMs = BleConstants.continuousThrottleMs - _sinceContinuousSend.elapsedMilliseconds;
          if (_sinceContinuousSend.isRunning && waitMs > 0) {
            await Future.delayed(Duration(milliseconds: waitMs));
            continue;
          }
          final key = _pendingMap.keys.first;
          item = _pendingMap.remove(key);
        }
        if (item == null) continue;
        if (item.continuous) {
          _sinceContinuousSend
            ..reset()
            ..start();
        }
        bool ok;
        try {
          ok = await item.execute(_transport);
        } catch (_) {
          ok = false;
        }
        // Only count real link drops, not commands attempted while offline.
        if (!ok && _transport.isConnected) _failureCount++;
      }
    } finally {
      _isSending = false;
    }
  }

  void dispose() {
    _disposed = true;
    _pendingMap.clear();
    _queue.clear();
  }
}
