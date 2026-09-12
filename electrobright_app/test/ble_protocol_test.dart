import 'package:flutter_test/flutter_test.dart';
import 'package:electrobright_app/core/ble/ble_protocol.dart';

void main() {
  group('BleProtocol Parser Tests', () {
    test('Correctly parses valid STATUS packet', () {
      const raw = 'STATUS:255,165,0,50,220,12,8,9,0,0,1\n';
      final status = BleProtocol.parseStatus(raw);

      expect(status, isNotNull);
      expect(status!.red, 255);
      expect(status.green, 165);
      expect(status.blue, 0);
      expect(status.white, 50);
      expect(status.brightness, 220);
      expect(status.mode, 12);
      expect(status.currentModeSpeed, 8);
      expect(status.currentModeFrequency, 9);
      expect(status.fireworkColorMode, 0);
      expect(status.clubColorMode, 0);
      expect(status.policeColorMode, 1);
    });

    test('Correctly parses complete 15-field STATUS packet matching firmware sendStatus()', () {
      const raw = 'STATUS:255,165,0,50,220,12,8,9,0,0,1,1,1,300,1\n';
      final status = BleProtocol.parseStatus(raw);

      expect(status, isNotNull);
      expect(status!.red, 255);
      expect(status.green, 165);
      expect(status.blue, 0);
      expect(status.white, 50);
      expect(status.brightness, 220);
      expect(status.mode, 12);
      expect(status.currentModeSpeed, 8);
      expect(status.currentModeFrequency, 9);
      expect(status.fireworkColorMode, 0);
      expect(status.clubColorMode, 0);
      expect(status.policeColorMode, 1);
      expect(status.sleeping, isTrue);
      expect(status.timerActive, isTrue);
      expect(status.timerRemainingSec, 300);
      expect(status.soundEnabled, isTrue);
    });

    test('Returns null on malformed STATUS packet', () {
      expect(BleProtocol.parseStatus('STATUS:255,100'), isNull);
      expect(BleProtocol.parseStatus('INVALID:1,2,3'), isNull);
    });

    test('Parses MODE_SETTINGS payload correctly', () {
      const raw = 'MODE_SETTINGS:5,5;6,8;9,10\n';
      final settings = BleProtocol.parseModeSettings(raw);

      expect(settings, isNotNull);
      expect(settings![1], {'speed': 5, 'frequency': 5});
      expect(settings[2], {'speed': 6, 'frequency': 8});
      expect(settings[3], {'speed': 9, 'frequency': 10});
    });

    test('Parses PRESETS list payload correctly', () {
      const raw = 'PRESETS:0,2,4,14,\n';
      final presets = BleProtocol.parsePresets(raw);

      expect(presets, isNotNull);
      expect(presets!.contains(0), isTrue);
      expect(presets.contains(2), isTrue);
      expect(presets.contains(4), isTrue);
      expect(presets.contains(14), isTrue);
      expect(presets.contains(1), isFalse);
    });

    test('Command formatting matches firmware expectations', () {
      expect(BleProtocol.setRgbw(255, 128, 0, 30), 'RGBW:255,128,0,30\n');
      expect(BleProtocol.setBrightness(200), 'BRIGHTNESS:200\n');
      expect(BleProtocol.setMode(12), 'MODE:12\n');
      expect(BleProtocol.setPoliceColorA(255, 0, 0, 0), 'POLICE_COLOR_A:255,0,0,0\n');
      expect(BleProtocol.setPoliceColorB(0, 0, 255, 0), 'POLICE_COLOR_B:0,0,255,0\n');
      expect(BleProtocol.savePreset(3), 'PRESET_SAVE:3\n');
      expect(BleProtocol.loadPreset(3), 'PRESET_LOAD:3\n');
      expect(BleProtocol.sleep(), 'SLEEP\n');
      expect(BleProtocol.factoryReset(), 'FACTORY_RESET\n');
    });
  });
}
