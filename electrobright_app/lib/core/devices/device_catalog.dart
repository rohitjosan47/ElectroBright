import 'package:flutter/material.dart';
import 'device_profile.dart';
import '../../features/dashboard/domain/mode_definition.dart';

/// Single source of truth for every hardware model the app understands.
/// To support a new physical product: add one DeviceProfile here.
class DeviceCatalog {
  /// The existing, already-shipped fixture. This is `ElectroBright_ESP32C3_BLE.ino` v2.6.0+,
  /// unchanged behaviorally — it is just now *modeled* as one entry instead of being baked
  /// into every provider.
  static const DeviceProfile electrobrightC3RgbwV1 = DeviceProfile(
    id: 'electrobright_c3_rgbw_v1',
    displayName: 'ElectroBright RGBW Fixture',
    icon: Icons.lightbulb_outline_rounded,
    advertisedNamePrefixes: const ['ElectroBright_BLE', 'ElectroBright_C3_'],
    legacyInfoIdentifiers: const ['ElectroBright_ESP32C3_BLE'],
    structuredModelId: 'EB-C3-RGBW-V1',
    serviceUuid: '6E400001-B5A3-F393-E0A9-E50E24DCCA9E',
    rxCharacteristicUuid: '6E400002-B5A3-F393-E0A9-E50E24DCCA9E',
    txCharacteristicUuid: '6E400003-B5A3-F393-E0A9-E50E24DCCA9E',
    numModes: 13,
    // SYNC NOTICE: Must match NUM_PRESETS in ElectroBright_ESP32C3_BLE.ino
    numPresets: 25,
    minSpeed: 1,
    maxSpeed: 10,
    minFrequency: 1,
    maxFrequency: 10,
    maxBrightness: 255,
    maxTimerMinutes: 1440,
    modes: ModeDefinition.allModes,
  );

  /// A safe minimal profile used ONLY when a scanned/connected device cannot be positively
  /// identified (unknown INFO reply, unknown advertised-name prefix). Assumes the least
  /// capability so the UI never reaches for a control the hardware doesn't have.
  static DeviceProfile genericFallbackProfile(String observedName) => DeviceProfile(
        id: 'generic_unverified',
        displayName: observedName.isNotEmpty ? observedName : 'Unrecognized ElectroBright Light',
        icon: Icons.help_outline_rounded,
        advertisedNamePrefixes: const [],
        legacyInfoIdentifiers: const [],
        serviceUuid: electrobrightC3RgbwV1.serviceUuid,
        rxCharacteristicUuid: electrobrightC3RgbwV1.rxCharacteristicUuid,
        txCharacteristicUuid: electrobrightC3RgbwV1.txCharacteristicUuid,
        numModes: 1,
        numPresets: 0,
        minSpeed: 1,
        maxSpeed: 10,
        minFrequency: 1,
        maxFrequency: 10,
        maxBrightness: 255,
        maxTimerMinutes: 1440,
        supportsSound: false,
        supportsTimer: false,
        supportsFactoryReset: false,
        modes: [ModeDefinition.allModes.first], // Mode 1 = Solid Color, always safe
      );

  static const List<DeviceProfile> allProfiles = [
    electrobrightC3RgbwV1,
  ];

  static DeviceProfile getById(String id) => allProfiles.firstWhere(
        (p) => p.id == id,
        orElse: () => electrobrightC3RgbwV1,
      );
}
