import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'ble_link.dart';

/// One traced link event.
final class TraceEntry {
  TraceEntry(this.at, this.kind, this.text);
  final DateTime at;
  final String kind; // 'tx', 'txnr', 'rx', 'link'
  final String text;

  @override
  String toString() => '${at.toIso8601String().substring(11, 23)} $kind $text';
}

/// A ring buffer of protocol traffic for diagnostics and export.
final class BleTrace {
  BleTrace({this.capacity = 2000});
  final int capacity;
  final ListQueue<TraceEntry> _entries = ListQueue<TraceEntry>();

  List<TraceEntry> get entries => List<TraceEntry>.unmodifiable(_entries);

  void add(String kind, String text) {
    _entries.add(TraceEntry(DateTime.now(), kind, text));
    while (_entries.length > capacity) {
      _entries.removeFirst();
    }
  }

  String export() => _entries.join('\n');

  void clear() => _entries.clear();

  static String render(List<int> bytes) {
    final bool text = bytes.every(
      (int b) => b == 0x0A || (b >= 0x20 && b < 0x7F),
    );
    if (text) return String.fromCharCodes(bytes).replaceAll('\n', r'\n');
    return bytes.map((int b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
  }
}

/// Decorates a link so every write and notification is traced.
final class TracingLink implements BleLink {
  TracingLink(this._inner, this._trace) {
    _trace.add('link', 'connected $deviceId mtu $mtu');
    unawaited(
      _inner.closed.then(
        (LinkLossReason r) => _trace.add('link', 'closed ($r)'),
      ),
    );
  }

  final BleLink _inner;
  final BleTrace _trace;

  @override
  String get deviceId => _inner.deviceId;
  @override
  int get mtu => _inner.mtu;
  @override
  Future<LinkLossReason> get closed => _inner.closed;

  @override
  Stream<Uint8List> subscribe(GattRef ref) =>
      _inner.subscribe(ref).map((Uint8List v) {
        _trace.add('rx', BleTrace.render(v));
        return v;
      });

  @override
  Future<void> write(
    GattRef ref,
    Uint8List value, {
    required bool withResponse,
  }) {
    _trace.add(withResponse ? 'tx' : 'txnr', BleTrace.render(value));
    return _inner.write(ref, value, withResponse: withResponse);
  }

  @override
  Future<void> disconnect() => _inner.disconnect();
}
