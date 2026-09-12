import 'dart:async';
import 'dart:convert';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'ble_transport.dart';
import '../devices/device_catalog.dart';

/// Physical Bluetooth Low Energy transport implementation using flutter_blue_plus.
class PhysicalBleTransport implements BleTransport {
  final _connectionController = StreamController<DeviceConnectionState>.broadcast();
  final _notificationsController = StreamController<String>.broadcast();
  final _scanResultsController = StreamController<List<DiscoveredDevice>>.broadcast();

  BluetoothDevice? _connectedDevice;
  BluetoothCharacteristic? _rxCharacteristic; // Write
  BluetoothCharacteristic? _txCharacteristic; // Notify
  StreamSubscription? _adapterStateSubscription;
  StreamSubscription? _connectionStateSubscription;
  StreamSubscription? _notificationSubscription;
  StreamSubscription? _scanResultsSubscription;

  DeviceConnectionState _state = DeviceConnectionState.disconnected;
  String _rxBuffer = '';

  PhysicalBleTransport() {
    _connectionController.add(_state);
    _adapterStateSubscription = FlutterBluePlus.adapterState.listen((state) {
      if (state != BluetoothAdapterState.on && isConnected) {
        disconnect();
      }
    });
  }

  @override
  Stream<DeviceConnectionState> get connectionStateStream => _connectionController.stream;

  @override
  Stream<String> get notificationsStream => _notificationsController.stream;

  @override
  Stream<List<DiscoveredDevice>> get scanResultsStream => _scanResultsController.stream;

  @override
  DeviceConnectionState get currentConnectionState => _state;

  @override
  bool get isConnected => _state == DeviceConnectionState.connected;

  @override
  Future<void> startScan({Duration timeout = const Duration(seconds: 5)}) async {
    _state = DeviceConnectionState.scanning;
    _connectionController.add(_state);

    _scanResultsSubscription?.cancel();
    _scanResultsSubscription = FlutterBluePlus.scanResults.listen((results) {
      final List<DiscoveredDevice> devices = [];
      for (final r in results) {
        final name = r.device.platformName.isNotEmpty
            ? r.device.platformName
            : r.advertisementData.advName;
        final validPrefixes = DeviceCatalog.allProfiles.expand((p) => p.advertisedNamePrefixes);
        final isMatch = validPrefixes.any((prefix) => name.startsWith(prefix));
        
        if (isMatch) {
          devices.add(DiscoveredDevice(
            id: r.device.remoteId.str,
            name: name.isEmpty ? 'ElectroBright Fixture' : name,
            rssi: r.rssi,
          ));
        }
      }
      _scanResultsController.add(devices);
    });

    try {
      await FlutterBluePlus.startScan(timeout: timeout);
    } catch (_) {
      stopScan();
    }
  }

  @override
  Future<void> stopScan() async {
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}
    if (_state == DeviceConnectionState.scanning) {
      _state = DeviceConnectionState.disconnected;
      _connectionController.add(_state);
    }
  }

  @override
  Future<bool> connect(String deviceId) async {
    await stopScan();
    _state = DeviceConnectionState.connecting;
    _connectionController.add(_state);

    try {
      final device = BluetoothDevice.fromId(deviceId);
      _connectedDevice = device;

      await device.connect(timeout: const Duration(seconds: 8));

      _connectionStateSubscription?.cancel();
      _connectionStateSubscription = device.connectionState.listen((connState) {
        if (connState == BluetoothConnectionState.disconnected) {
          _cleanUpConnection();
          _state = DeviceConnectionState.disconnected;
          _connectionController.add(_state);
        }
      });

      // Request MTU 512 for high-speed packet delivery
      try {
        await device.requestMtu(512);
      } catch (_) {}

      const defaultProfile = DeviceCatalog.electrobrightC3RgbwV1;

      // Discover Services
      final services = await device.discoverServices();
      final targetService = services.firstWhere(
        (s) => s.uuid.str128.toUpperCase() == defaultProfile.serviceUuid.toUpperCase(),
        orElse: () => throw Exception('Nordic UART Service not found'),
      );

      for (final char in targetService.characteristics) {
        final uuid = char.uuid.str128.toUpperCase();
        if (uuid == defaultProfile.rxCharacteristicUuid.toUpperCase()) {
          _rxCharacteristic = char;
        } else if (uuid == defaultProfile.txCharacteristicUuid.toUpperCase()) {
          _txCharacteristic = char;
        }
      }

      if (_rxCharacteristic == null || _txCharacteristic == null) {
        throw Exception('Required NUS characteristics not found');
      }

      // Subscribe to Notifications
      const int maxRxBufferBytes = 4096;
      await _txCharacteristic!.setNotifyValue(true);
      _notificationSubscription = _txCharacteristic!.onValueReceived.listen((value) {
        final chunk = utf8.decode(value, allowMalformed: true);
        _rxBuffer += chunk;
        if (_rxBuffer.length > maxRxBufferBytes) {
          _rxBuffer = '';
        }
        while (_rxBuffer.contains('\n')) {
          final newlineIdx = _rxBuffer.indexOf('\n');
          final line = _rxBuffer.substring(0, newlineIdx).trim();
          _rxBuffer = _rxBuffer.substring(newlineIdx + 1);
          if (line.isNotEmpty) {
            _notificationsController.add(line);
          }
        }
      });

      _state = DeviceConnectionState.connected;
      _connectionController.add(_state);
      return true;
    } catch (e) {
      await disconnect();
      return false;
    }
  }

  @override
  Future<void> disconnect() async {
    _state = DeviceConnectionState.disconnecting;
    _connectionController.add(_state);
    try {
      await _connectedDevice?.disconnect();
    } catch (_) {}
    _cleanUpConnection();
    _state = DeviceConnectionState.disconnected;
    _connectionController.add(_state);
  }

  void _cleanUpConnection() {
    _notificationSubscription?.cancel();
    _connectionStateSubscription?.cancel();
    _rxCharacteristic = null;
    _txCharacteristic = null;
    _connectedDevice = null;
    _rxBuffer = '';
  }

  @override
  Future<bool> sendRaw(String data) async {
    if (_rxCharacteristic == null || !isConnected) return false;
    try {
      final bytes = utf8.encode(data.endsWith('\n') ? data : '$data\n');
      await _rxCharacteristic!.write(bytes, withoutResponse: false);
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> sendBytes(List<int> bytes, {bool withoutResponse = false}) async {
    if (_rxCharacteristic == null || !isConnected) return false;
    try {
      await _rxCharacteristic!.write(bytes, withoutResponse: withoutResponse);
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  void dispose() {
    _cleanUpConnection();
    _adapterStateSubscription?.cancel();
    _scanResultsSubscription?.cancel();
    _connectionController.close();
    _notificationsController.close();
    _scanResultsController.close();
  }
}
