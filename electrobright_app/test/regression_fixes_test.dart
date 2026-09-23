import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:electrobright_app/core/ble/ble_dispatcher.dart';
import 'package:electrobright_app/core/ble/ble_protocol.dart';
import 'package:electrobright_app/core/ble/ble_transport.dart';
import 'package:electrobright_app/core/ble/mock_ble_transport.dart';
import 'package:electrobright_app/core/devices/device_catalog.dart';
import 'package:electrobright_app/core/devices/paired_device.dart';
import 'package:electrobright_app/core/utils/echo_suppressor.dart';
import 'package:electrobright_app/features/connection/application/connection_notifier.dart';
import 'package:electrobright_app/features/dashboard/application/device_notifier.dart';
import 'package:electrobright_app/features/devices/application/device_library_notifier.dart';
import 'package:electrobright_app/features/presets/data/preset_name_repository.dart';

/// Regression tests for the defects fixed in the stability pass (IDs refer to
/// the analysis plan: A1..A14).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockBleTransport transport;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    transport = MockBleTransport()..connectDelay = const Duration(milliseconds: 5);
  });

  tearDown(() => transport.dispose());

  DeviceNotifier makeNotifier(BleDispatcher dispatcher, {String deviceId = 'dev'}) => DeviceNotifier(
        transport,
        dispatcher,
        EchoSuppressor(),
        PresetNameRepository(deviceId, 25),
        DeviceCatalog.electrobrightC3RgbwV1,
      );

  test('A1: renaming the active device does not rebuild/reset the DeviceNotifier', () async {
    final device = PairedDevice(
      id: 'dev-1',
      profileId: DeviceCatalog.electrobrightC3RgbwV1.id,
      label: 'Desk',
      addedAt: DateTime(2026),
    );
    SharedPreferences.setMockInitialValues({
      'electrobright_paired_devices_v1': [device.toJson()],
      'electrobright_active_device_id_v1': 'dev-1',
    });
    final container = ProviderContainer(overrides: [bleTransportProvider.overrideWithValue(transport)]);
    addTearDown(container.dispose);

    container.read(deviceLibraryProvider);
    await Future.delayed(const Duration(milliseconds: 20)); // library load
    final before = container.read(deviceStateProvider.notifier);
    before.setMode(7);

    await container.read(deviceLibraryProvider.notifier).renameDevice('dev-1', 'Living Room');
    await container.read(deviceLibraryProvider.notifier).touchLastConnected('dev-1');

    expect(identical(container.read(deviceStateProvider.notifier), before), isTrue);
    expect(container.read(deviceStateProvider).mode, 7);
  });

  test('A1: a notifier created while already connected syncs version and caps', () async {
    await transport.connect('MOCK');
    final dispatcher = BleDispatcher(transport);
    final notifier = makeNotifier(dispatcher);
    await Future.delayed(const Duration(milliseconds: 200));

    expect(notifier.state.firmwareVersion, '2.9.0');
    expect(notifier.state.supportsBinaryFastPath, isTrue);
    notifier.dispose();
    dispatcher.dispose();
  });

  test('A2: scanning while connected keeps the link usable', () async {
    await transport.connect('MOCK');
    await transport.startScan();
    expect(transport.isConnected, isTrue);
    await transport.stopScan();
    expect(transport.isConnected, isTrue);
  });

  test('A3: hardware PRESETS list prunes stale cached names and snapshots', () async {
    final dispatcher = BleDispatcher(transport);
    final notifier = makeNotifier(dispatcher);
    await Future.delayed(Duration.zero);

    notifier.savePreset(2);
    await notifier.renamePreset(2, 'Old Name');
    expect(notifier.state.getPresetName(2), 'Old Name');
    // Let the save + PRESET_LIST round-trip with the (mock) hardware finish.
    await Future.delayed(const Duration(milliseconds: 100));
    expect(notifier.state.savedPresets, {2});

    // Hardware says slot 2 is empty (e.g. deleted elsewhere / factory reset).
    transport.simulateIncomingNotification('PRESETS:');
    await Future.delayed(const Duration(milliseconds: 20));

    expect(notifier.state.savedPresets, isEmpty);
    expect(notifier.state.getPresetName(2), 'Preset 3');
    expect((await const PresetNameRepository('dev', 25).loadPresetNames())[2], isNull);

    // Saving a new preset into the emptied slot starts with the default name.
    notifier.savePreset(2);
    expect(notifier.state.getPresetName(2), 'Preset 3');
    notifier.dispose();
    dispatcher.dispose();
  });

  test('A5: a live STATUS does not overwrite the active preset snapshot', () async {
    final dispatcher = BleDispatcher(transport);
    final notifier = makeNotifier(dispatcher);
    notifier.setRgbw(10, 20, 30, 0, continuous: false);
    notifier.savePreset(0);
    expect(notifier.state.activePresetId, 0);

    transport.simulateIncomingNotification('STATUS:200,200,200,0,255,1,5,5,0,0,1,0,0,0,1');
    await Future.delayed(Duration.zero);

    expect(notifier.state.presetSnapshots[0]!.red, 10);
    notifier.dispose();
    dispatcher.dispose();
  });

  test('A12: police colors are parsed from the extended STATUS', () async {
    final parsed = BleProtocol.parseStatus('STATUS:1,2,3,4,255,12,5,5,0,0,0,0,0,0,1,9,8,7,6,5,4,3,2');
    expect(parsed!.policeColorA, [9, 8, 7, 6]);
    expect(parsed.policeColorB, [5, 4, 3, 2]);

    final legacy = BleProtocol.parseStatus('STATUS:1,2,3,4,255,12,5,5,0,0,0,0,0,0,1');
    expect(legacy!.policeColorA, isNull);

    final dispatcher = BleDispatcher(transport);
    final notifier = makeNotifier(dispatcher);
    transport.simulateIncomingNotification('STATUS:1,2,3,4,255,12,5,5,0,0,0,0,0,0,1,9,8,7,6,5,4,3,2');
    await Future.delayed(Duration.zero);
    expect(notifier.state.policeColorAR, 9);
    expect(notifier.state.policeColorBW, 2);
    notifier.dispose();
    dispatcher.dispose();
  });

  test('A11: malformed CAPS reply does not throw', () async {
    final dispatcher = BleDispatcher(transport);
    final notifier = makeNotifier(dispatcher);
    transport.simulateIncomingNotification('CAPS:PROTOCOL=abc');
    await Future.delayed(Duration.zero);
    expect(notifier.state.supportsBinaryFastPath, isFalse);
    notifier.dispose();
    dispatcher.dispose();
  });

  test('A8: continuous traffic is throttled and the final value is always delivered', () async {
    await transport.connect('MOCK');
    final dispatcher = BleDispatcher(transport);
    for (int i = 0; i < 100; i++) {
      dispatcher.dispatchBinary(BleProtocol.encodeRgbwBrightnessBinary(i, 0, 0, 0, 255));
      await Future.delayed(const Duration(milliseconds: 3));
    }
    dispatcher.dispatchBinary(
      BleProtocol.encodeRgbwBrightnessBinary(250, 1, 2, 3, 200),
      priority: CommandPriority.immediate,
    );
    await Future.delayed(const Duration(milliseconds: 100));

    // ~300 ms of dragging at a 30 ms throttle => roughly 10 packets, not 100.
    expect(transport.binaryPacketCount, lessThan(20));
    final status = <String>[];
    final sub = transport.notificationsStream.listen(status.add);
    await transport.sendRaw('STATUS');
    await Future.delayed(Duration.zero);
    expect(BleProtocol.parseStatus(status.first)!.red, 250);
    await sub.cancel();
    dispatcher.dispose();
  });

  test('A7: a non-user disconnect that passes through `disconnecting` auto-reconnects', () async {
    final notifier = ConnectionNotifier(
      transport,
      backoffDelays: const [Duration(milliseconds: 10)],
    );
    await notifier.connect(const DiscoveredDevice(id: 'MOCK', name: 'ElectroBright_C3_V1', rssi: -50));
    await Future.delayed(const Duration(milliseconds: 20));
    expect(notifier.state.state, DeviceConnectionState.connected);

    // Transport-originated disconnect (e.g. adapter blip / write failure path).
    await transport.disconnect();
    await Future.delayed(const Duration(milliseconds: 100));
    expect(notifier.state.state, DeviceConnectionState.connected);
    notifier.dispose();
  });
}
