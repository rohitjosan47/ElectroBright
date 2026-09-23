import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'ble_link.dart';

/// Serialises every write on one link: at most one GATT write is outstanding,
/// in submission order. (iOS tracks reliable writes per characteristic and
/// Android allows one GATT operation at a time; interleaving writes from the
/// command and colour lanes would otherwise fail or reorder.)
final class LinkWriter {
  LinkWriter(this._link);

  final BleLink _link;
  final Queue<_PendingWrite> _queue = Queue<_PendingWrite>();
  bool _busy = false;
  bool _closed = false;
  int writes = 0;
  int failures = 0;

  /// True while a write is queued or in flight.
  bool get isBusy => _busy || _queue.isNotEmpty;

  Future<void> write(
    GattRef ref,
    Uint8List value, {
    required bool withResponse,
  }) {
    if (_closed) {
      return Future<void>.error(
        const LinkClosedException(LinkLossReason.failed),
      );
    }
    final _PendingWrite w = _PendingWrite(ref, value, withResponse);
    _queue.add(w);
    _pump();
    return w.done.future;
  }

  /// Fails every queued write; the link is gone.
  void close(LinkLossReason reason) {
    _closed = true;
    while (_queue.isNotEmpty) {
      _queue.removeFirst().done.completeError(LinkClosedException(reason));
    }
  }

  void _pump() {
    if (_busy || _queue.isEmpty) return;
    _busy = true;
    final _PendingWrite w = _queue.removeFirst();
    unawaited(
      _link
          .write(w.ref, w.value, withResponse: w.withResponse)
          .then(
            (_) {
              writes++;
              w.done.complete();
            },
            onError: (Object e, StackTrace s) {
              failures++;
              w.done.completeError(e, s);
            },
          )
          .whenComplete(() {
            _busy = false;
            _pump();
          }),
    );
  }
}

final class _PendingWrite {
  _PendingWrite(this.ref, this.value, this.withResponse);
  final GattRef ref;
  final Uint8List value;
  final bool withResponse;
  final Completer<void> done = Completer<void>();
}
