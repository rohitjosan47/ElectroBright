import 'dart:async';

enum DeviceConnectionState {
  disconnected,
  scanning,
  connecting,
  connected,
  disconnecting,
}

class DiscoveredDevice {
  final String id;
  final String name;
  final int rssi;

  const DiscoveredDevice({
    required this.id,
    required this.name,
    required this.rssi,
  });
}

/// Abstract transport interface decoupling BLE hardware operations from UI/Domain logic.
abstract class BleTransport {
  Stream<DeviceConnectionState> get connectionStateStream;
  Stream<String> get notificationsStream;
  DeviceConnectionState get currentConnectionState;
  bool get isConnected => currentConnectionState == DeviceConnectionState.connected;

  Future<void> startScan({Duration timeout = const Duration(seconds: 5)});
  Future<void> stopScan();
  Stream<List<DiscoveredDevice>> get scanResultsStream;

  Future<bool> connect(String deviceId);
  Future<void> disconnect();
  Future<bool> sendRaw(String data);
  void dispose();
}
