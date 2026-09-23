import 'dart:async';
import 'dart:typed_data';

import 'package:meta/meta.dart';

/// A GATT characteristic address (UUIDs lower-case, 128-bit or 16-bit form).
@immutable
final class GattRef {
  const GattRef(this.service, this.characteristic);
  final String service;
  final String characteristic;

  @override
  bool operator ==(Object other) =>
      other is GattRef &&
      other.service == service &&
      other.characteristic == characteristic;

  @override
  int get hashCode => Object.hash(service, characteristic);

  @override
  String toString() => '$service/$characteristic';
}

/// Why a link ended.
enum LinkLossReason {
  /// We asked for it.
  requested,

  /// The peripheral went away (out of range, powered off, supervision timeout).
  lost,

  /// Bluetooth was switched off or became unavailable.
  adapterOff,

  /// A GATT operation failed in a way that leaves the link unusable.
  failed,
}

/// A connected link to one peripheral, reduced to what drivers need. The
/// production implementation wraps flutter_reactive_ble; tests use fwsim or
/// the in-app simulator.
abstract interface class BleLink {
  String get deviceId;

  /// Negotiated ATT MTU (23 until an exchange happened).
  int get mtu;

  /// Enables notifications on [ref]. Payloads arrive in order.
  Stream<Uint8List> subscribe(GattRef ref);

  /// One GATT write. Without response it completes when the stack accepted
  /// it; with response, when the peripheral acknowledged it. Throws
  /// [LinkClosedException] once the link is gone.
  Future<void> write(
    GattRef ref,
    Uint8List value, {
    required bool withResponse,
  });

  /// Completes once when the link ends.
  Future<LinkLossReason> get closed;

  Future<void> disconnect();
}

final class LinkClosedException implements Exception {
  const LinkClosedException(this.reason);
  final LinkLossReason reason;
  @override
  String toString() => 'LinkClosedException($reason)';
}
