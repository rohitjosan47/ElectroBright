/// ElectroBright firmware contract (firmware/ElectroBright/src/config/Config.h).
/// `test/cross_repo/firmware_config_sync_test.dart` checks every value
/// against the firmware sources.
abstract final class Eb {
  // Nordic UART Service.
  static const String serviceUuid = '6e400001-b5a3-f393-e0a9-e50e24dcca9e';
  static const String rxUuid = '6e400002-b5a3-f393-e0a9-e50e24dcca9e';
  static const String txUuid = '6e400003-b5a3-f393-e0a9-e50e24dcca9e';

  /// Advertised-name prefix of firmware 3.x (name is in the scan response).
  static const String namePrefix = 'ElectroBright_C3_';

  /// Advertised name of the original (pre-3.x) firmware.
  static const String legacyName = 'ElectroBright_BLE';

  /// INFO reply of the original firmware.
  static const String legacyInfo = 'ElectroBright_ESP32C3_BLE';

  /// Model ids of the current family, e.g. EB-C3-RGBW-V1.
  static final RegExp modelPattern = RegExp(r'^EB-[A-Z0-9]+-([A-Z]+)-V\d+$');

  static const int numModes = 13;
  static const int numPresets = 25;
  static const int minLevel = 1;
  static const int maxLevel = 10;
  static const int timerMaxSeconds = 86400;
  static const int maxLineLength = 96;
  static const int statusFields = 23;
  static const int protocolVersion = 1;
  static const int minFirmwareMajor = 3;

  /// Bytes per notification/write before the MTU exchange (ATT MTU 23 - 3).
  static const int minPayload = 20;
}
