import 'dart:async';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'ble_link.dart';

/// Bluetooth availability on the phone.
enum BleAdapterState {
  unknown,

  /// No Bluetooth LE on this device.
  unsupported,

  /// The user has not allowed Bluetooth for the app.
  unauthorized,

  /// Bluetooth is switched off.
  poweredOff,

  /// Android 11 and older: scanning also needs Location Services.
  locationServicesDisabled,
  ready,
}

/// How hard to scan (Android scan modes; iOS scans one way).
enum ScanIntensity { lowPower, balanced, lowLatency }

/// One advertisement (or scan response) from a peripheral.
@immutable
final class Advertisement {
  const Advertisement({
    required this.id,
    required this.name,
    required this.rssi,
    required this.serviceUuids,
    required this.manufacturerData,
    required this.connectable,
  });

  /// Platform peripheral id (a UUID on iOS, the MAC address on Android).
  final String id;

  /// Local name; may be empty until the scan response arrives.
  final String name;
  final int rssi;

  /// Lower-case UUID strings.
  final List<String> serviceUuids;

  /// Starts with the 16-bit company id (little endian).
  final Uint8List manufacturerData;
  final bool connectable;
}

/// Failure to establish a link.
final class ConnectException implements Exception {
  const ConnectException(this.message, {this.gattStatus});
  final String message;

  /// Android GATT status (133 is the notorious generic failure).
  final int? gattStatus;
  @override
  String toString() => 'ConnectException($message, status: $gattStatus)';
}

/// The phone's BLE central role, reduced to what the app needs. Implemented by
/// [ReactiveBleCentral] (real radio) and SimCentral (demo lights, tests).
abstract interface class BleCentral {
  /// Current state, then every change.
  Stream<BleAdapterState> get adapterState;
  BleAdapterState get currentAdapterState;

  /// Starts a scan; cancelling the subscription stops it. [services] filters
  /// by advertised service UUIDs (empty = everything).
  Stream<Advertisement> scan({
    List<String> services = const <String>[],
    ScanIntensity intensity = ScanIntensity.balanced,
  });

  /// Connects and prepares a link: services discovered, MTU negotiated.
  /// [timeout] null = wait until the peripheral appears (iOS favourites).
  Future<BleLink> connect(
    String deviceId, {
    required Map<String, List<String>> services,
    Duration? timeout,
  });

  /// Android: forget cached GATT tables (recovery after repeated status 133).
  Future<void> clearCache(String deviceId);
}
