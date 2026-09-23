import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:electrobright_app/core/ble/ble_transport.dart';
import 'package:electrobright_app/core/ble/mock_ble_transport.dart';
import 'package:electrobright_app/core/ble/ble_dispatcher.dart';
import 'package:electrobright_app/core/devices/device_catalog.dart';
import 'package:electrobright_app/core/utils/echo_suppressor.dart';
import 'package:electrobright_app/features/connection/application/connection_notifier.dart';
import 'package:electrobright_app/features/dashboard/application/device_notifier.dart';
import 'package:electrobright_app/features/presets/data/preset_name_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Tier 1: Persistence Tests', () {
    late MockBleTransport transport;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      transport = MockBleTransport();
      transport.connectDelay = const Duration(milliseconds: 10);
    });

    tearDown(() {
      transport.dispose();
    });

    test('Connecting to device persists lastConnectedDeviceId & restores on app restart', () async {
      final notifier1 = ConnectionNotifier(transport);
      await Future.delayed(Duration.zero);

      const testDevice = DiscoveredDevice(
        id: 'EB-FIXTURE-AA11',
        name: 'ElectroBright Studio',
        rssi: -55,
      );

      final connected = await notifier1.connect(testDevice);
      expect(connected, isTrue);
      expect(notifier1.state.lastConnectedDeviceId, 'EB-FIXTURE-AA11');
      expect(notifier1.state.connectedDeviceName, 'ElectroBright Studio');

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(ConnectionNotifier.prefLastDeviceId), 'EB-FIXTURE-AA11');
      expect(prefs.getString(ConnectionNotifier.prefLastDeviceName), 'ElectroBright Studio');
      notifier1.dispose();

      // Simulate App Restart by instantiating fresh ConnectionNotifier
      final notifier2 = ConnectionNotifier(transport);
      await Future.delayed(const Duration(milliseconds: 50));

      expect(notifier2.state.lastConnectedDeviceId, 'EB-FIXTURE-AA11');
      expect(notifier2.state.connectedDeviceName, 'ElectroBright Studio');
      notifier2.dispose();
    });

    test('activePresetId is debounced and restored on app start', () async {
      final dispatcher = BleDispatcher(transport);
      final echoSuppressor = EchoSuppressor();
      const presetRepo = PresetNameRepository('test-fixture', 25);

      final notifier = DeviceNotifier(
        transport,
        dispatcher,
        echoSuppressor,
        presetRepo,
        DeviceCatalog.electrobrightC3RgbwV1,
      );
      await Future.delayed(Duration.zero);

      // Save a Club scene into slot 1, then recall it
      notifier.setMode(9);
      notifier.savePreset(1);
      notifier.setMode(1);
      notifier.loadPreset(1);
      expect(notifier.state.activePresetId, 1);
      expect(notifier.state.mode, 9);

      // Before 500ms debounce completes, storage has not committed
      expect(await presetRepo.loadActivePresetId(), isNull);

      // Wait past the 500ms coalescing window
      await Future.delayed(const Duration(milliseconds: 550));
      expect(await presetRepo.loadActivePresetId(), 1);

      notifier.dispose();

      // Simulate App Restart with fresh DeviceNotifier
      final restartedNotifier = DeviceNotifier(
        transport,
        dispatcher,
        echoSuppressor,
        presetRepo,
        DeviceCatalog.electrobrightC3RgbwV1,
      );

      // Wait for _loadPersistedPresets async load
      await Future.delayed(const Duration(milliseconds: 50));

      // Only the highlight is restored; live color/mode come from the
      // hardware STATUS, never from a cached snapshot (A5).
      expect(restartedNotifier.state.activePresetId, 1);
      expect(restartedNotifier.state.savedPresets, contains(1));
      expect(restartedNotifier.state.mode, 1);

      // Modifying controls directly clears active preset
      restartedNotifier.setRgbw(200, 200, 0, 0, continuous: false);
      expect(restartedNotifier.state.activePresetId, isNull);

      // Wait past debounce window
      await Future.delayed(const Duration(milliseconds: 550));
      expect(await presetRepo.loadActivePresetId(), isNull);

      restartedNotifier.dispose();
      dispatcher.dispose();
      echoSuppressor.dispose();
    });
  });

  group('Tier 1: Bounded Reconnect Tests', () {
    late MockBleTransport transport;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      transport = MockBleTransport();
      transport.connectDelay = const Duration(milliseconds: 10);
    });

    tearDown(() {
      transport.dispose();
    });

    test('Unexpected BLE drop initiates backed-off reconnection and recovers', () async {
      final notifier = ConnectionNotifier(
        transport,
        backoffDelays: const [
          Duration(milliseconds: 40),
          Duration(milliseconds: 80),
          Duration(milliseconds: 160),
        ],
        maxReconnectAttempts: 3,
      );

      const testDevice = DiscoveredDevice(
        id: 'MOCK-DROP-001',
        name: 'ElectroBright Beacon',
        rssi: -62,
      );

      await notifier.connect(testDevice);
      expect(notifier.state.state, DeviceConnectionState.connected);

      // Simulate unexpected signal drop
      transport.simulateDeviceDrop();
      await Future.delayed(Duration.zero);

      // State transitions to reconnecting
      expect(notifier.state.state, DeviceConnectionState.reconnecting);
      expect(notifier.state.reconnectAttempt, 1);

      // Wait for the 40ms backoff + 10ms connectDelay
      await Future.delayed(const Duration(milliseconds: 70));

      // Successfully recovered
      expect(notifier.state.state, DeviceConnectionState.connected);
      expect(notifier.state.reconnectAttempt, 0);

      notifier.dispose();
    });

    test('Bounded retry: stops after max attempts without infinite loop', () async {
      final notifier = ConnectionNotifier(
        transport,
        backoffDelays: const [
          Duration(milliseconds: 20),
          Duration(milliseconds: 30),
          Duration(milliseconds: 40),
        ],
        maxReconnectAttempts: 3,
      );

      const testDevice = DiscoveredDevice(
        id: 'MOCK-FAIL-001',
        name: 'ElectroBright OutOfRange',
        rssi: -90,
      );

      await notifier.connect(testDevice);
      expect(notifier.state.state, DeviceConnectionState.connected);

      // Make all reconnect attempts fail
      transport.failNextConnect = true;

      // Simulate unexpected signal drop
      transport.simulateDeviceDrop();
      await Future.delayed(Duration.zero);

      expect(notifier.state.state, DeviceConnectionState.reconnecting);

      // Wait for all 3 attempts to cycle: (20+10) + (30+10) + (40+10) = 120ms + buffer
      await Future.delayed(const Duration(milliseconds: 250));

      // Retries must halt at disconnected
      expect(notifier.state.state, DeviceConnectionState.disconnected);
      expect(notifier.state.reconnectAttempt, 0);

      notifier.dispose();
    });

    test('User-initiated disconnect cancels active reconnect permanently', () async {
      final notifier = ConnectionNotifier(
        transport,
        backoffDelays: const [
          Duration(milliseconds: 500),
          Duration(milliseconds: 1000),
        ],
        maxReconnectAttempts: 2,
      );

      const testDevice = DiscoveredDevice(
        id: 'MOCK-CANCEL-001',
        name: 'ElectroBright LivingRoom',
        rssi: -50,
      );

      await notifier.connect(testDevice);
      expect(notifier.state.state, DeviceConnectionState.connected);

      // Drop connection
      transport.simulateDeviceDrop();
      await Future.delayed(Duration.zero);

      expect(notifier.state.state, DeviceConnectionState.reconnecting);
      expect(notifier.state.reconnectAttempt, 1);

      // User explicitly taps disconnect
      await notifier.disconnect();

      expect(notifier.state.state, DeviceConnectionState.disconnected);
      expect(notifier.state.reconnectAttempt, 0);

      // Wait past backoff delay and confirm no reconnect happened
      await Future.delayed(const Duration(milliseconds: 600));
      expect(notifier.state.state, DeviceConnectionState.disconnected);

      notifier.dispose();
    });
  });
}
