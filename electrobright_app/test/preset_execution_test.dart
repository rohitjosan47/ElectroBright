import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:electrobright_app/core/ble/mock_ble_transport.dart';
import 'package:electrobright_app/core/ble/ble_dispatcher.dart';
import 'package:electrobright_app/core/utils/echo_suppressor.dart';
import 'package:electrobright_app/features/presets/data/preset_name_repository.dart';
import 'package:electrobright_app/features/dashboard/application/device_notifier.dart';
import 'package:electrobright_app/core/devices/device_catalog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Preset Execution & Reactive UI State Tests (Offline & Connected)', () {
    late MockBleTransport transport;
    late BleDispatcher dispatcher;
    late EchoSuppressor suppressor;
    late PresetNameRepository presetRepo;
    late DeviceNotifier notifier;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
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

    test('Fresh state has no demo presets (APP-PRESET-01)', () {
      expect(notifier.state.savedPresets, isEmpty);
      expect(notifier.state.presetSnapshots, isEmpty);
      expect(notifier.state.getPresetName(0), 'Preset 1');
    });

    test('Loading a saved Candle scene immediately restores mode, brightness, color and speeds', () {
      notifier.setMode(13);
      notifier.setBrightness(240, continuous: false);
      notifier.setSpeed(6, continuous: false);
      notifier.setFrequency(7, continuous: false);
      notifier.setRgbw(255, 140, 0, 60, continuous: false);
      notifier.savePreset(0);

      notifier.setMode(1);
      notifier.setBrightness(255, continuous: false);
      notifier.setRgbw(255, 255, 255, 0, continuous: false);

      notifier.loadPreset(0);

      expect(notifier.state.activePresetId, 0);
      expect(notifier.state.mode, 13);
      expect(notifier.state.brightness, 240);
      expect(notifier.state.red, 255);
      expect(notifier.state.green, 140);
      expect(notifier.state.blue, 0);
      expect(notifier.state.white, 60);
      expect(notifier.state.currentSpeed, 6);
      expect(notifier.state.currentFrequency, 7);
    });

    test('Loading a saved Police scene restores mode and both custom beacon colors', () {
      notifier.setMode(12);
      notifier.setPoliceColorMode(0);
      notifier.setPoliceColorA(255, 0, 0, 0);
      notifier.setPoliceColorB(0, 0, 255, 0);
      notifier.savePreset(4);

      notifier.setMode(1);
      notifier.setPoliceColorA(1, 2, 3, 4);

      notifier.loadPreset(4);
      expect(notifier.state.activePresetId, 4);
      expect(notifier.state.mode, 12);
      expect(notifier.state.policeColorMode, 0);
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
      notifier.savePreset(0);
      notifier.loadPreset(0);
      expect(notifier.state.activePresetId, 0);

      notifier.deletePreset(0);
      expect(notifier.state.savedPresets.contains(0), isFalse);
      expect(notifier.state.presetSnapshots.containsKey(0), isFalse);
      expect(notifier.state.activePresetId, isNull);
    });
  });
}
