import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/ble/ble_transport.dart';
import '../../dashboard/application/device_notifier.dart';

class ConnectionUiState {
  final DeviceConnectionState state;
  final List<DiscoveredDevice> discoveredDevices;
  final String? connectedDeviceName;

  const ConnectionUiState({
    required this.state,
    required this.discoveredDevices,
    this.connectedDeviceName,
  });

  factory ConnectionUiState.initial() => const ConnectionUiState(
        state: DeviceConnectionState.disconnected,
        discoveredDevices: [],
      );

  ConnectionUiState copyWith({
    DeviceConnectionState? state,
    List<DiscoveredDevice>? discoveredDevices,
    String? connectedDeviceName,
    bool clearConnectedDeviceName = false,
  }) {
    return ConnectionUiState(
      state: state ?? this.state,
      discoveredDevices: discoveredDevices ?? this.discoveredDevices,
      connectedDeviceName: clearConnectedDeviceName ? null : (connectedDeviceName ?? this.connectedDeviceName),
    );
  }
}

final connectionProvider =
    StateNotifierProvider<ConnectionNotifier, ConnectionUiState>((ref) {
  final transport = ref.watch(bleTransportProvider);
  return ConnectionNotifier(transport);
});

class ConnectionNotifier extends StateNotifier<ConnectionUiState> {
  final BleTransport _transport;
  StreamSubscription? _connSub;
  StreamSubscription? _scanSub;

  ConnectionNotifier(this._transport) : super(ConnectionUiState.initial()) {
    _connSub = _transport.connectionStateStream.listen((cState) {
      state = state.copyWith(state: cState);
    });
    _scanSub = _transport.scanResultsStream.listen((devices) {
      state = state.copyWith(discoveredDevices: devices);
    });
  }

  Future<void> startScan() async {
    await _transport.startScan();
  }

  Future<void> stopScan() async {
    await _transport.stopScan();
  }

  Future<bool> connect(DiscoveredDevice device) async {
    state = state.copyWith(connectedDeviceName: device.name);
    return await _transport.connect(device.id);
  }

  Future<void> disconnect() async {
    await _transport.disconnect();
    state = state.copyWith(clearConnectedDeviceName: true);
  }

  @override
  void dispose() {
    _connSub?.cancel();
    _scanSub?.cancel();
    super.dispose();
  }
}
