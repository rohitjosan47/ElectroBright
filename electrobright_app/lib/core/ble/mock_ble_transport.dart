import 'dart:async';
import 'ble_transport.dart';
import '../devices/device_catalog.dart';

class SimulatedPreset {
  final int red;
  final int green;
  final int blue;
  final int white;
  final int brightness;
  final int mode;
  final int speed;
  final int freq;
  final int fireworkColorMode;
  final int clubColorMode;
  final int policeColorMode;

  const SimulatedPreset({
    required this.red,
    required this.green,
    required this.blue,
    required this.white,
    required this.brightness,
    required this.mode,
    required this.speed,
    required this.freq,
    required this.fireworkColorMode,
    required this.clubColorMode,
    required this.policeColorMode,
  });
}

/// In-memory hardware simulator that replicates the ESP32-C3 firmware state machine.
/// Enables 100% offline development, widget testing, and simulator previews.
class MockBleTransport implements BleTransport {
  final _connectionController = StreamController<DeviceConnectionState>.broadcast();
  final _notificationsController = StreamController<String>.broadcast();
  final _scanResultsController = StreamController<List<DiscoveredDevice>>.broadcast();

  DeviceConnectionState _state = DeviceConnectionState.disconnected;

  // Simulated Hardware State (Mirrors ESP32 SystemState)
  bool _isSleeping = false;
  bool _soundEnabled = true;
  bool _timerActive = false;
  int _timerRemainingSec = 0;
  Timer? _simulatedTimer;
  int _red = 255;
  int _green = 165;
  int _blue = 0;
  int _white = 0;
  int _brightness = 220;
  int _mode = 1;
  final List<int> _modeSpeed = List.filled(DeviceCatalog.electrobrightC3RgbwV1.numModes, 5);
  final List<int> _modeFrequency = List.filled(DeviceCatalog.electrobrightC3RgbwV1.numModes, 5);
  int _fireworkColorMode = 0;
  int _clubColorMode = 0;
  int _policeColorMode = 1;

  // Full in-memory preset memory storage
  final Map<int, SimulatedPreset> _presetStorage = {};

  MockBleTransport() {
    _connectionController.add(_state);

    // Seed realistic, distinctive default presets for slots 0..4
    _presetStorage[0] = const SimulatedPreset(
      red: 255,
      green: 140,
      blue: 0,
      white: 60,
      brightness: 240,
      mode: 13, // Candle
      speed: 6,
      freq: 7,
      fireworkColorMode: 0,
      clubColorMode: 0,
      policeColorMode: 1,
    );

    _presetStorage[1] = const SimulatedPreset(
      red: 255,
      green: 0,
      blue: 180,
      white: 0,
      brightness: 255,
      mode: 9, // Club Lights
      speed: 8,
      freq: 8,
      fireworkColorMode: 0,
      clubColorMode: 0,
      policeColorMode: 1,
    );

    _presetStorage[2] = const SimulatedPreset(
      red: 0,
      green: 245,
      blue: 160,
      white: 0,
      brightness: 190,
      mode: 3, // Breath
      speed: 5,
      freq: 8,
      fireworkColorMode: 0,
      clubColorMode: 0,
      policeColorMode: 1,
    );

    _presetStorage[3] = const SimulatedPreset(
      red: 0,
      green: 229,
      blue: 255,
      white: 0,
      brightness: 230,
      mode: 10, // Rainbow
      speed: 5,
      freq: 6,
      fireworkColorMode: 0,
      clubColorMode: 0,
      policeColorMode: 1,
    );

    _presetStorage[4] = const SimulatedPreset(
      red: 255,
      green: 0,
      blue: 68,
      white: 0,
      brightness: 255,
      mode: 12, // Police Strobe
      speed: 9,
      freq: 10,
      fireworkColorMode: 0,
      clubColorMode: 0,
      policeColorMode: 1,
    );
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

    Future.delayed(const Duration(milliseconds: 300), () {
      _scanResultsController.add([
        DiscoveredDevice(
          id: 'MOCK-ESP32-C3-001',
          name: DeviceCatalog.electrobrightC3RgbwV1.advertisedNamePrefixes.first,
          rssi: -58,
        ),
      ]);
    });
  }

  @override
  Future<void> stopScan() async {
    if (_state == DeviceConnectionState.scanning) {
      _state = DeviceConnectionState.disconnected;
      _connectionController.add(_state);
    }
  }

  bool failNextConnect = false;
  Duration connectDelay = const Duration(milliseconds: 100);
  int binaryPacketCount = 0;
  int asciiCommandCount = 0;
  String simulatedVersion = '2.8.0';

  @override
  Future<bool> connect(String deviceId) async {
    _state = DeviceConnectionState.connecting;
    _connectionController.add(_state);

    await Future.delayed(connectDelay);
    if (failNextConnect) {
      _state = DeviceConnectionState.disconnected;
      _connectionController.add(_state);
      return false;
    }

    _state = DeviceConnectionState.connected;
    _connectionController.add(_state);

    _broadcastStatus();
    return true;
  }

  /// Simulates an unexpected BLE drop (e.g. out-of-range signal loss).
  void simulateDeviceDrop() {
    if (_state == DeviceConnectionState.connected) {
      _state = DeviceConnectionState.disconnected;
      _connectionController.add(_state);
    }
  }

  @override
  Future<void> disconnect() async {
    _state = DeviceConnectionState.disconnecting;
    _connectionController.add(_state);
    await Future.delayed(const Duration(milliseconds: 150));
    _state = DeviceConnectionState.disconnected;
    _connectionController.add(_state);
  }

  @override
  Future<bool> sendRaw(String data) async {
    final clean = data.trim();
    if (clean.isEmpty) return false;

    asciiCommandCount++;
    await Future.delayed(const Duration(milliseconds: 10));

    if (clean.startsWith('RGBW:')) {
      final parts = clean.substring(5).split(',');
      if (parts.length == 4) {
        _red = int.parse(parts[0]);
        _green = int.parse(parts[1]);
        _blue = int.parse(parts[2]);
        _white = int.parse(parts[3]);
        _notificationsController.add('OK\n');
      }
    } else if (clean.startsWith('BRIGHTNESS:')) {
      _brightness = int.parse(clean.substring(11));
      _notificationsController.add('OK\n');
    } else if (clean.startsWith('MODE:')) {
      _mode = int.parse(clean.substring(5));
      _notificationsController.add('OK\n');
      _broadcastStatus();
    } else if (clean.startsWith('SPEED:')) {
      _modeSpeed[_mode - 1] = int.parse(clean.substring(6));
      _notificationsController.add('OK\n');
    } else if (clean.startsWith('FREQUENCY:')) {
      _modeFrequency[_mode - 1] = int.parse(clean.substring(10));
      _notificationsController.add('OK\n');
    } else if (clean.startsWith('FIREWORK_COLOR_MODE:')) {
      _fireworkColorMode = int.parse(clean.substring(20));
      _notificationsController.add('OK\n');
    } else if (clean.startsWith('CLUB_COLOR_MODE:')) {
      _clubColorMode = int.parse(clean.substring(16));
      _notificationsController.add('OK\n');
    } else if (clean.startsWith('POLICE_COLOR_MODE:')) {
      _policeColorMode = int.parse(clean.substring(18));
      _notificationsController.add('OK\n');
    } else if (clean.startsWith('POLICE_COLOR_A:')) {
      _notificationsController.add('OK\n');
    } else if (clean.startsWith('POLICE_COLOR_B:')) {
      _notificationsController.add('OK\n');
    } else if (clean.startsWith('PRESET_SAVE:')) {
      final id = int.parse(clean.substring(12));
      _presetStorage[id] = SimulatedPreset(
        red: _red,
        green: _green,
        blue: _blue,
        white: _white,
        brightness: _brightness,
        mode: _mode,
        speed: _modeSpeed[_mode - 1],
        freq: _modeFrequency[_mode - 1],
        fireworkColorMode: _fireworkColorMode,
        clubColorMode: _clubColorMode,
        policeColorMode: _policeColorMode,
      );
      _notificationsController.add('OK\n');
      _broadcastPresetList();
    } else if (clean.startsWith('PRESET_LOAD:')) {
      final id = int.parse(clean.substring(12));
      if (_presetStorage.containsKey(id)) {
        final p = _presetStorage[id]!;
        _red = p.red;
        _green = p.green;
        _blue = p.blue;
        _white = p.white;
        _brightness = p.brightness;
        _mode = p.mode;
        _modeSpeed[_mode - 1] = p.speed;
        _modeFrequency[_mode - 1] = p.freq;
        _fireworkColorMode = p.fireworkColorMode;
        _clubColorMode = p.clubColorMode;
        _policeColorMode = p.policeColorMode;
        // Hardware broadcasts STATUS on preset load!
        _broadcastStatus();
      } else {
        _notificationsController.add('ERROR:PRESET_EMPTY:$id\n');
      }
    } else if (clean.startsWith('PRESET_DELETE:')) {
      final id = int.parse(clean.substring(14));
      _presetStorage.remove(id);
      _notificationsController.add('OK\n');
      _broadcastPresetList();
    } else if (clean.startsWith('TIMER:')) {
      final mins = int.parse(clean.substring(6));
      _simulatedTimer?.cancel();
      if (mins > 0) {
        _timerActive = true;
        _timerRemainingSec = mins * 60;
        _simulatedTimer = Timer.periodic(const Duration(seconds: 1), (t) {
          if (_timerRemainingSec > 0) {
            _timerRemainingSec--;
          } else {
            _timerActive = false;
            _isSleeping = true;
            t.cancel();
            _broadcastStatus();
          }
        });
      } else {
        _timerActive = false;
        _timerRemainingSec = 0;
      }
      _notificationsController.add('OK\n');
    } else if (clean == 'SLEEP') {
      _isSleeping = true;
      _notificationsController.add('OK\n');
    } else if (clean == 'WAKE') {
      _isSleeping = false;
      _notificationsController.add('OK\n');
    } else if (clean == 'SOUND_ON') {
      _soundEnabled = true;
      _notificationsController.add('OK\n');
    } else if (clean == 'SOUND_OFF') {
      _soundEnabled = false;
      _notificationsController.add('OK\n');
    } else if (clean == 'FACTORY_RESET') {
      _presetStorage.clear();
      _modeSpeed.fillRange(0, _modeSpeed.length, 5);
      _modeFrequency.fillRange(0, _modeFrequency.length, 5);
      _red = 255; _green = 255; _blue = 255; _white = 0; _brightness = 255; _mode = 1;
      _notificationsController.add('OK\n');
    } else if (clean == 'PING') {
      _notificationsController.add('OK\n');
    } else if (clean == 'INFO') {
      _notificationsController.add('INFO:ElectroBright_ESP32C3_BLE\n');
    } else if (clean == 'STATUS') {
      _broadcastStatus();
    } else if (clean == 'MODE_SETTINGS') {
      _broadcastModeSettings();
    } else if (clean == 'PRESET_LIST') {
      _broadcastPresetList();
    } else if (clean == 'VERSION') {
      _notificationsController.add('VERSION:$simulatedVersion\n');
    }

    return true;
  }

  @override
  Future<bool> sendBytes(List<int> bytes, {bool withoutResponse = false}) async {
    if (bytes.length == 6 && bytes[0] == 0xAA) {
      final r = bytes[1];
      final g = bytes[2];
      final b = bytes[3];
      final w = bytes[4];
      final expectedChecksum = (r ^ g ^ b ^ w ^ 0x55) & 0xFF;
      if (bytes[5] == expectedChecksum) {
        binaryPacketCount++;
        _red = r;
        _green = g;
        _blue = b;
        _white = w;
        _isSleeping = false;
        // Binary fast path bypasses notifications
        return true;
      }
    }
    return false;
  }

  void _broadcastStatus() {
    final payload = 'STATUS:$_red,$_green,$_blue,$_white,$_brightness,$_mode,'
        '${_modeSpeed[_mode - 1]},${_modeFrequency[_mode - 1]},'
        '$_fireworkColorMode,$_clubColorMode,$_policeColorMode,'
        '${_isSleeping ? 1 : 0},${_timerActive ? 1 : 0},$_timerRemainingSec,${_soundEnabled ? 1 : 0}\n';
    _notificationsController.add(payload);
  }

  void _broadcastModeSettings() {
    final buffer = StringBuffer('MODE_SETTINGS:');
    for (int i = 0; i < DeviceCatalog.electrobrightC3RgbwV1.numModes; i++) {
      buffer.write('${_modeSpeed[i]},${_modeFrequency[i]}');
      if (i < DeviceCatalog.electrobrightC3RgbwV1.numModes - 1) buffer.write(';');
    }
    buffer.write('\n');
    _notificationsController.add(buffer.toString());
  }

  void _broadcastPresetList() {
    final buffer = StringBuffer('PRESETS:');
    for (final id in _presetStorage.keys) {
      buffer.write('$id,');
    }
    buffer.write('\n');
    _notificationsController.add(buffer.toString());
  }

  void simulateIncomingNotification(String data) {
    _notificationsController.add(data);
  }

  @override
  void dispose() {
    _connectionController.close();
    _notificationsController.close();
    _scanResultsController.close();
  }
}
