import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../core/ble/ble_transport.dart';
import '../../dashboard/application/device_notifier.dart';

class ConnectionUiState {
  final DeviceConnectionState state;
  final List<DiscoveredDevice> discoveredDevices;
  final String? connectedDeviceName;
  final String? lastConnectedDeviceId;
  final int reconnectAttempt;
  final int maxReconnectAttempts;

  const ConnectionUiState({
    required this.state,
    required this.discoveredDevices,
    this.connectedDeviceName,
    this.lastConnectedDeviceId,
    this.reconnectAttempt = 0,
    this.maxReconnectAttempts = 3,
  });

  factory ConnectionUiState.initial() => const ConnectionUiState(
        state: DeviceConnectionState.disconnected,
        discoveredDevices: [],
        reconnectAttempt: 0,
        maxReconnectAttempts: 3,
      );

  ConnectionUiState copyWith({
    DeviceConnectionState? state,
    List<DiscoveredDevice>? discoveredDevices,
    String? connectedDeviceName,
    bool clearConnectedDeviceName = false,
    String? lastConnectedDeviceId,
    bool clearLastConnectedDeviceId = false,
    int? reconnectAttempt,
    int? maxReconnectAttempts,
  }) {
    return ConnectionUiState(
      state: state ?? this.state,
      discoveredDevices: discoveredDevices ?? this.discoveredDevices,
      connectedDeviceName: clearConnectedDeviceName ? null : (connectedDeviceName ?? this.connectedDeviceName),
      lastConnectedDeviceId: clearLastConnectedDeviceId ? null : (lastConnectedDeviceId ?? this.lastConnectedDeviceId),
      reconnectAttempt: reconnectAttempt ?? this.reconnectAttempt,
      maxReconnectAttempts: maxReconnectAttempts ?? this.maxReconnectAttempts,
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
  final List<Duration> _backoffDelays;
  StreamSubscription? _connSub;
  StreamSubscription? _scanSub;
  Timer? _reconnectTimer;
  bool _userInitiatedDisconnect = false;
  bool _isReconnecting = false;

  static const String prefLastDeviceId = 'electrobright_last_connected_device_id';
  static const String prefLastDeviceName = 'electrobright_last_connected_device_name';

  ConnectionNotifier(
    this._transport, {
    List<Duration>? backoffDelays,
    int maxReconnectAttempts = 3,
  })  : _backoffDelays = backoffDelays ??
            const [
              Duration(seconds: 1),
              Duration(seconds: 2),
              Duration(seconds: 4),
            ],
        super(ConnectionUiState.initial().copyWith(maxReconnectAttempts: maxReconnectAttempts)) {
    _init();
  }

  Future<void> _init() async {
    _connSub = _transport.connectionStateStream.listen(_handleConnectionStateChange);
    _scanSub = _transport.scanResultsStream.listen((devices) {
      state = state.copyWith(discoveredDevices: devices);
    });
    await _loadPersistedDevice();
  }

  Future<void> _loadPersistedDevice() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final lastId = prefs.getString(prefLastDeviceId);
      final lastName = prefs.getString(prefLastDeviceName);
      if (lastId != null && lastId.isNotEmpty) {
        state = state.copyWith(
          lastConnectedDeviceId: lastId,
          connectedDeviceName: state.connectedDeviceName ?? lastName,
        );
      }
    } catch (_) {}
  }

  Future<void> _savePersistedDevice(String id, String name) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(prefLastDeviceId, id);
      await prefs.setString(prefLastDeviceName, name);
    } catch (_) {}
  }

  void _handleConnectionStateChange(DeviceConnectionState cState) {
    if (_userInitiatedDisconnect) {
      if (cState == DeviceConnectionState.disconnected) {
        _isReconnecting = false;
        state = state.copyWith(state: cState, reconnectAttempt: 0);
      }
      return;
    }

    if (_isReconnecting) {
      // While actively reconnecting, _scheduleReconnect manages transitions
      return;
    }

    if (cState == DeviceConnectionState.connected) {
      _reconnectTimer?.cancel();
      _isReconnecting = false;
      state = state.copyWith(state: cState, reconnectAttempt: 0);
    } else if (cState == DeviceConnectionState.disconnected) {
      final wasConnected = state.state == DeviceConnectionState.connected;
      if (wasConnected &&
          state.lastConnectedDeviceId != null &&
          state.maxReconnectAttempts > 0) {
        _isReconnecting = true;
        _scheduleReconnect();
      } else {
        state = state.copyWith(state: cState, reconnectAttempt: 0);
      }
    } else {
      state = state.copyWith(state: cState);
    }
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    if (_userInitiatedDisconnect) {
      _isReconnecting = false;
      return;
    }

    if (state.reconnectAttempt >= state.maxReconnectAttempts) {
      _isReconnecting = false;
      state = state.copyWith(
        state: DeviceConnectionState.disconnected,
        reconnectAttempt: 0,
      );
      return;
    }

    final nextAttempt = state.reconnectAttempt + 1;
    state = state.copyWith(
      state: DeviceConnectionState.reconnecting,
      reconnectAttempt: nextAttempt,
    );

    final delayIndex = (nextAttempt - 1).clamp(0, _backoffDelays.length - 1);
    final delay = _backoffDelays[delayIndex];

    _reconnectTimer = Timer(delay, () async {
      if (!mounted || _userInitiatedDisconnect) {
        _isReconnecting = false;
        return;
      }
      final targetId = state.lastConnectedDeviceId;
      if (targetId == null) {
        _isReconnecting = false;
        state = state.copyWith(
          state: DeviceConnectionState.disconnected,
          reconnectAttempt: 0,
        );
        return;
      }

      final success = await _transport.connect(targetId);
      if (!mounted || _userInitiatedDisconnect) {
        _isReconnecting = false;
        return;
      }

      if (success) {
        _isReconnecting = false;
        _userInitiatedDisconnect = false;
        state = state.copyWith(
          state: DeviceConnectionState.connected,
          reconnectAttempt: 0,
        );
      } else {
        if (state.reconnectAttempt >= state.maxReconnectAttempts) {
          _isReconnecting = false;
          state = state.copyWith(
            state: DeviceConnectionState.disconnected,
            reconnectAttempt: 0,
          );
        } else {
          _scheduleReconnect();
        }
      }
    });
  }

  Future<void> startScan() async {
    await _transport.startScan();
  }

  Future<void> stopScan() async {
    await _transport.stopScan();
  }

  Future<bool> connect(DiscoveredDevice device) async {
    _userInitiatedDisconnect = false;
    _isReconnecting = false;
    _reconnectTimer?.cancel();
    state = state.copyWith(
      connectedDeviceName: device.name,
      lastConnectedDeviceId: device.id,
      reconnectAttempt: 0,
    );
    final success = await _transport.connect(device.id);
    if (success) {
      await _savePersistedDevice(device.id, device.name);
    }
    return success;
  }

  Future<void> disconnect() async {
    _userInitiatedDisconnect = true;
    _isReconnecting = false;
    _reconnectTimer?.cancel();
    await _transport.disconnect();
    state = state.copyWith(
      clearConnectedDeviceName: true,
      reconnectAttempt: 0,
      state: DeviceConnectionState.disconnected,
    );
  }

  @override
  void dispose() {
    _userInitiatedDisconnect = true;
    _isReconnecting = false;
    _reconnectTimer?.cancel();
    _connSub?.cancel();
    _scanSub?.cancel();
    super.dispose();
  }
}
