import 'dart:async';
import 'dart:collection';
import 'ble_transport.dart';
import 'ble_constants.dart';

/// Command priority classification.
enum CommandPriority {
  immediate,   // High priority (Mode change, Power, Preset, Settings)
  continuous,  // Low priority, high frequency (Sliders: Brightness, RGBW, Speed, Freq)
}

abstract class _DispatcherItem {
  Future<void> execute(BleTransport transport);
}

class _StringItem implements _DispatcherItem {
  final String command;
  _StringItem(this.command);

  @override
  Future<void> execute(BleTransport transport) async {
    await transport.sendRaw(command).timeout(const Duration(seconds: 5));
  }
}

class _BinaryItem implements _DispatcherItem {
  final List<int> bytes;
  _BinaryItem(this.bytes);

  @override
  Future<void> execute(BleTransport transport) async {
    await transport.sendBytes(bytes, withoutResponse: true).timeout(const Duration(seconds: 5));
  }
}

/// Smart BLE Command Dispatcher featuring:
/// 1. Coalescing Leaky-Bucket Throttle: Prevents BLE buffer overflow while dragging sliders.
/// 2. Stream Deduplication: Redundant intermediate values are replaced in-flight.
/// 3. Guaranteed Terminal Dispatch: Final touch release is guaranteed to send immediately.
/// 4. Binary Fast-Path Support: Seamlessly routes raw byte streams for high-speed color updates.
class BleDispatcher {
  final BleTransport _transport;
  Timer? _throttleTimer;
  String? _pendingContinuousCommand;
  List<int>? _pendingContinuousBinary;
  bool _isSending = false;
  final Queue<_DispatcherItem> _queue = Queue();

  BleDispatcher(this._transport);

  /// Dispatches an ASCII command with priority-aware throttling.
  void dispatch(String command, {CommandPriority priority = CommandPriority.immediate}) {
    if (priority == CommandPriority.immediate) {
      // Flush any pending continuous first, then execute immediate
      flushPending();
      _enqueue(_StringItem(command));
      return;
    }

    // Continuous priority (e.g., slider drag)
    _pendingContinuousCommand = command;
    _pendingContinuousBinary = null;

    if (_throttleTimer == null || !_throttleTimer!.isActive) {
      _throttleTimer = Timer(const Duration(milliseconds: BleConstants.continuousThrottleMs), () {
        flushPending();
      });
    }
  }

  /// Dispatches a raw binary packet (e.g. fast-path color streaming) with priority-aware throttling.
  void dispatchBinary(List<int> bytes, {CommandPriority priority = CommandPriority.continuous}) {
    if (priority == CommandPriority.immediate) {
      flushPending();
      _enqueue(_BinaryItem(bytes));
      return;
    }

    // Continuous priority (e.g., color wheel drag)
    _pendingContinuousBinary = bytes;
    _pendingContinuousCommand = null;

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
      _enqueue(_StringItem(cmd));
    } else if (_pendingContinuousBinary != null) {
      final bytes = _pendingContinuousBinary!;
      _pendingContinuousBinary = null;
      _enqueue(_BinaryItem(bytes));
    }
  }

  void _enqueue(_DispatcherItem item) {
    _queue.add(item);
    _drain();
  }

  Future<void> _drain() async {
    if (_isSending) return;
    _isSending = true;
    while (_queue.isNotEmpty) {
      final item = _queue.removeFirst();
      try {
        await item.execute(_transport);
      } catch (_) {}
    }
    _isSending = false;
  }

  void dispose() {
    _throttleTimer?.cancel();
  }
}
