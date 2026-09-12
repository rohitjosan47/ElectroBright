import 'dart:async';
import 'dart:collection';
import 'ble_transport.dart';
import 'ble_constants.dart';

/// Command priority classification.
enum CommandPriority {
  immediate,   // High priority (Mode change, Power, Preset, Settings)
  continuous,  // Low priority, high frequency (Sliders: Brightness, RGBW, Speed, Freq)
}

/// Smart BLE Command Dispatcher featuring:
/// 1. Coalescing Leaky-Bucket Throttle: Prevents BLE buffer overflow while dragging sliders.
/// 2. Stream Deduplication: Redundant intermediate values are replaced in-flight.
/// 3. Guaranteed Terminal Dispatch: Final touch release is guaranteed to send immediately.
class BleDispatcher {
  final BleTransport _transport;
  Timer? _throttleTimer;
  String? _pendingContinuousCommand;
  bool _isSending = false;
  final Queue<String> _queue = Queue();

  BleDispatcher(this._transport);

  /// Dispatches a command with priority-aware throttling.
  void dispatch(String command, {CommandPriority priority = CommandPriority.immediate}) {
    if (priority == CommandPriority.immediate) {
      // Flush any pending continuous first, then execute immediate
      flushPending();
      _enqueue(command);
      return;
    }

    // Continuous priority (e.g., slider drag)
    _pendingContinuousCommand = command;

    if (_throttleTimer == null || !_throttleTimer!.isActive) {
      _throttleTimer = Timer(const Duration(milliseconds: BleConstants.continuousThrottleMs), () {
        flushPending();
      });
    }
  }

  /// Forces any in-flight throttled command to be sent immediately (e.g., on pointer up).
  void flushPending() {
    _throttleTimer?.cancel();
    _throttleTimer = null;
    if (_pendingContinuousCommand != null) {
      final cmd = _pendingContinuousCommand!;
      _pendingContinuousCommand = null;
      _enqueue(cmd);
    }
  }

  void _enqueue(String command) {
    _queue.add(command);
    _drain();
  }

  Future<void> _drain() async {
    if (_isSending) return;
    _isSending = true;
    while (_queue.isNotEmpty) {
      final cmd = _queue.removeFirst();
      try {
        await _transport.sendRaw(cmd).timeout(const Duration(seconds: 5));
      } catch (_) {}
    }
    _isSending = false;
  }

  void dispose() {
    _throttleTimer?.cancel();
  }
}
