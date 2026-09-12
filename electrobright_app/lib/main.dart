import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'app.dart';
import 'core/ble/ble_transport.dart';
import 'core/ble/physical_ble_transport.dart';
import 'core/ble/mock_ble_transport.dart';
import 'features/dashboard/application/device_notifier.dart';

import 'core/devices/legacy_migration_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await LegacyMigrationService.run();

  // Smart Transport Detection:
  // On iOS Simulator or desktop debugging, use MockBleTransport to guarantee 100% interactive UI.
  // On physical iOS/Android devices, use PhysicalBleTransport with flutter_blue_plus.
  BleTransport transport;

  // Set to true if you explicitly want to test with the virtual ESP32 simulator
  const bool forceMockTransport = false;

  if (forceMockTransport || kIsWeb) {
    transport = MockBleTransport();
  } else {
    try {
      if (Platform.isIOS || Platform.isAndroid) {
        transport = PhysicalBleTransport();
      } else {
        transport = MockBleTransport();
      }
    } catch (_) {
      transport = MockBleTransport();
    }
  }

  runApp(
    ProviderScope(
      overrides: [
        bleTransportProvider.overrideWithValue(transport),
      ],
      child: const ElectroBrightApp(),
    ),
  );
}
