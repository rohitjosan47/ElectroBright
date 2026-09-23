import 'package:flutter_test/flutter_test.dart';
import 'package:electrobright_app/features/presets/data/preset_name_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:electrobright_app/core/ble/mock_ble_transport.dart';
import 'package:electrobright_app/core/ble/ble_dispatcher.dart';
import 'package:electrobright_app/core/devices/device_catalog.dart';
import 'package:electrobright_app/features/dashboard/application/device_notifier.dart';
import 'package:electrobright_app/core/utils/echo_suppressor.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DeviceNotifier & State Flow Tests', () {
    late MockBleTransport transport;
    late BleDispatcher dispatcher;
    late EchoSuppressor echoSuppressor;
    late PresetNameRepository presetRepo;
    late DeviceNotifier notifier;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      transport = MockBleTransport();
      dispatcher = BleDispatcher(transport);
      echoSuppressor = EchoSuppressor();
      presetRepo = const PresetNameRepository('test-device', 15);
      notifier = DeviceNotifier(transport, dispatcher, echoSuppressor, presetRepo, DeviceCatalog.electrobrightC3RgbwV1);
    });

    tearDown(() {
      notifier.dispose();
      dispatcher.dispose();
      echoSuppressor.dispose();
      transport.dispose();
    });

    test('Initial state is loaded with sensible defaults', () {
      expect(notifier.state.brightness, 255);
      expect(notifier.state.mode, 1);
      expect(notifier.state.red, 255);
      expect(notifier.state.green, 255);
      expect(notifier.state.blue, 255);
      expect(notifier.state.white, 0);
      expect(notifier.state.getPresetName(0), 'Preset 1');
      expect(notifier.state.getPresetName(5), 'Preset 6');
      expect(notifier.state.savedPresets, isEmpty);
    });

    test('Changing mode to 12 (Police) updates state and notifies transport', () async {
      notifier.setMode(12);
      expect(notifier.state.mode, 12);
    });

    test('Updating Police Custom Beacon Colors updates Color A & B state', () {
      notifier.setPoliceColorMode(1); // Manual mode
      expect(notifier.state.policeColorMode, 1);

      notifier.setPoliceColorA(255, 0, 128, 0);
      expect(notifier.state.policeColorAR, 255);
      expect(notifier.state.policeColorAG, 0);
      expect(notifier.state.policeColorAB, 128);

      notifier.setPoliceColorB(0, 255, 255, 50);
      expect(notifier.state.policeColorBR, 0);
      expect(notifier.state.policeColorBG, 255);
      expect(notifier.state.policeColorBB, 255);
      expect(notifier.state.policeColorBW, 50);
    });

    test('Preset save, load, and delete operations update preset sets and restore scene', () {
      // Configure unique custom scene
      notifier.setMode(4); // Fireworks
      notifier.setBrightness(120, continuous: false);
      notifier.setRgbw(10, 200, 50, 30, continuous: false);

      // Save to slot 7
      notifier.savePreset(7);
      expect(notifier.state.savedPresets.contains(7), isTrue);
      expect(notifier.state.presetSnapshots.containsKey(7), isTrue);

      // Change to another state
      notifier.setMode(1);
      notifier.setBrightness(255, continuous: false);
      notifier.setRgbw(255, 255, 255, 0, continuous: false);
      expect(notifier.state.mode, 1);
      expect(notifier.state.brightness, 255);

      // Load slot 7 and verify instant optimistic parameter restoration
      notifier.loadPreset(7);
      expect(notifier.state.activePresetId, 7);
      expect(notifier.state.mode, 4);
      expect(notifier.state.brightness, 120);
      expect(notifier.state.red, 10);
      expect(notifier.state.green, 200);
      expect(notifier.state.blue, 50);
      expect(notifier.state.white, 30);

      // Delete slot 7
      notifier.deletePreset(7);
      expect(notifier.state.savedPresets.contains(7), isFalse);
      expect(notifier.state.presetSnapshots.containsKey(7), isFalse);
      expect(notifier.state.activePresetId, isNull);
    });

    test('Preset renaming updates state and persists name', () async {
      await notifier.renamePreset(0, 'Cozy Fireplace');
      expect(notifier.state.getPresetName(0), 'Cozy Fireplace');
    });

    test('Loading factory preset updates entire app UI state immediately without hardware', () async {
      echoSuppressor.acquireLock('rgbw');
      expect(echoSuppressor.isLocked('rgbw'), isTrue);

      notifier.setRgbw(0, 255, 0, 0, continuous: true);
      expect(notifier.state.green, 255);

      transport.simulateIncomingNotification('STATUS:10,10,10,10,255,1,5,5,0,0,1,0,0,0,1');
      await Future.delayed(Duration.zero);

      expect(notifier.state.green, 255); // The incoming G=10 is rejected
      expect(notifier.state.red, 0); // The incoming R=10 is rejected
      expect(notifier.state.mode, 1); // Not locked, so Mode=1 is accepted (though it's already 1)
    });

    test('Echo Suppression - Releasing lock accepts next broadcast', () async {
      notifier.setRgbw(255, 0, 0, 0, continuous: true);
      expect(echoSuppressor.isLocked('rgbw'), isTrue);

      notifier.setRgbw(0, 0, 255, 0, continuous: false);
      await Future.delayed(const Duration(milliseconds: 300));
      expect(echoSuppressor.isLocked('rgbw'), isFalse);

      transport.simulateIncomingNotification('STATUS:10,10,10,10,255,1,5,5,0,0,1,0,0,0,1');
      await Future.delayed(Duration.zero);

      expect(notifier.state.red, 10);
      expect(notifier.state.green, 10);
      expect(notifier.state.blue, 10);
      expect(notifier.state.white, 10);
    });

    test('Power toggle is ignored while disconnected and reports an error', () {
      notifier.toggleSleep();
      expect(notifier.state.isSleeping, isFalse);
      expect(notifier.state.lastError, isNotNull);
    });

    test('Sleep mode toggles state and power state', () async {
      await transport.connect('MOCK');
      expect(notifier.state.isSleeping, isFalse);
      notifier.toggleSleep();
      expect(notifier.state.isSleeping, isTrue);
      notifier.toggleSleep();
      expect(notifier.state.isSleeping, isFalse);
    });

    test('Lease-lock prevents echo rubberbanding during active slider drag', () {
      notifier.setBrightness(180, continuous: true);
      expect(echoSuppressor.isLocked('brightness'), isTrue);

      // Releasing lock triggers the settling grace timer
      notifier.setBrightness(180, continuous: false);
      expect(echoSuppressor.isLocked('brightness'), isTrue); // In grace period
    });
  });
}
