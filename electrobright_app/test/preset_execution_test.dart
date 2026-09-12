import 'package:flutter_test/flutter_test.dart';
import 'package:electrobright_app/core/ble/mock_ble_transport.dart';
import 'package:electrobright_app/core/ble/ble_dispatcher.dart';
import 'package:electrobright_app/core/utils/echo_suppressor.dart';
import 'package:electrobright_app/features/presets/data/preset_name_repository.dart';
import 'package:electrobright_app/features/dashboard/application/device_notifier.dart';
import 'package:electrobright_app/core/devices/device_catalog.dart';

void main() {
  group('Preset Execution & Reactive UI State Tests (Offline & Connected)', () {
    late MockBleTransport transport;
    late BleDispatcher dispatcher;
    late EchoSuppressor suppressor;
    late PresetNameRepository presetRepo;
    late DeviceNotifier notifier;

    setUp(() {
      transport = MockBleTransport();
      dispatcher = BleDispatcher(transport);
      suppressor = EchoSuppressor();
      presetRepo = const PresetNameRepository('test-device', 15);
      notifier = DeviceNotifier(transport, dispatcher, suppressor, presetRepo, DeviceCatalog.electrobrightC3RgbwV1);
    });

    tearDown(() {
      notifier.dispose();
      dispatcher.dispose();
      suppressor.dispose();
      transport.dispose();
    });

    test('Tapping Preset 1 (Warm Candle) immediately updates mode, brightness, color and speeds', () {
      // Start in mode 1 Solid Color, 100% white
      expect(notifier.state.mode, 1);
      expect(notifier.state.brightness, 255);

      // Tap Preset 1 (Slot 0)
      notifier.loadPreset(0);

      // Verify immediate state transformation
      expect(notifier.state.activePresetId, 0);
      expect(notifier.state.mode, 13); // Candle
      expect(notifier.state.brightness, 240);
      expect(notifier.state.red, 255);
      expect(notifier.state.green, 140);
      expect(notifier.state.blue, 0);
      expect(notifier.state.white, 60);
      expect(notifier.state.currentSpeed, 6);
      expect(notifier.state.currentFrequency, 7);
    });

    test('Tapping Preset 2 (Cyber Club) immediately updates mode to 9 and color to neon magenta', () {
      notifier.loadPreset(1);

      expect(notifier.state.activePresetId, 1);
      expect(notifier.state.mode, 9); // Club Lights
      expect(notifier.state.brightness, 255);
      expect(notifier.state.red, 255);
      expect(notifier.state.green, 0);
      expect(notifier.state.blue, 180);
      expect(notifier.state.white, 0);
      expect(notifier.state.currentSpeed, 8);
      expect(notifier.state.currentFrequency, 8);
      expect(notifier.state.clubColorMode, 0);
    });

    test('Tapping Preset 5 (Police Warning) immediately updates to Police mode with dual beacons', () {
      notifier.loadPreset(4);

      expect(notifier.state.activePresetId, 4);
      expect(notifier.state.mode, 12); // Police Strobe
      expect(notifier.state.brightness, 255);
      expect(notifier.state.currentSpeed, 9);
      expect(notifier.state.currentFrequency, 10);
      expect(notifier.state.policeColorMode, 1);
      expect(notifier.state.policeColorAR, 255);
      expect(notifier.state.policeColorAB, 0);
      expect(notifier.state.policeColorBR, 0);
      expect(notifier.state.policeColorBB, 255);
    });

    test('Creating a custom preset, changing controls, and recalling it restores all sliders & wheel', () {
      // 1. User configures a custom look
      notifier.setMode(6); // Thunderstorm
      notifier.setBrightness(175, continuous: false);
      notifier.setSpeed(7, continuous: false);
      notifier.setFrequency(9, continuous: false);
      notifier.setRgbw(120, 0, 255, 40, continuous: false);

      // 2. User saves to Slot 8 (Preset 9)
      notifier.savePreset(8);
      expect(notifier.state.savedPresets.contains(8), isTrue);
      expect(notifier.state.activePresetId, 8);

      // 3. User switches to a completely different mode and color
      notifier.setMode(1); // Solid Color
      notifier.setBrightness(50, continuous: false);
      notifier.setRgbw(255, 255, 255, 0, continuous: false);
      expect(notifier.state.mode, 1);
      expect(notifier.state.brightness, 50);

      // 4. User recalls Slot 8 (Preset 9)
      notifier.loadPreset(8);

      // 5. Assert that ALL sliders, wheel, and mode are restored!
      expect(notifier.state.activePresetId, 8);
      expect(notifier.state.mode, 6);
      expect(notifier.state.brightness, 175);
      expect(notifier.state.currentSpeed, 7);
      expect(notifier.state.currentFrequency, 9);
      expect(notifier.state.red, 120);
      expect(notifier.state.green, 0);
      expect(notifier.state.blue, 255);
      expect(notifier.state.white, 40);
    });

    test('Deleting an active preset removes it from savedPresets and clears activePresetId', () {
      notifier.loadPreset(0);
      expect(notifier.state.activePresetId, 0);

      notifier.deletePreset(0);
      expect(notifier.state.savedPresets.contains(0), isFalse);
      expect(notifier.state.presetSnapshots.containsKey(0), isFalse);
      expect(notifier.state.activePresetId, isNull);
    });
  });
}
