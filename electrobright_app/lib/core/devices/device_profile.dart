import 'package:flutter/material.dart';
import '../../features/dashboard/domain/mode_definition.dart';

/// Describes one supported hardware model/SKU. Immutable, defined in source (device_catalog.dart),
/// never persisted, never user-editable. Adding a new physical product = adding one of these.
class DeviceProfile {
  /// Stable internal key, e.g. 'electrobright_c3_rgbw_v1'. Never changes once shipped — it is
  /// referenced by id from persisted PairedDevice records.
  final String id;

  /// User-facing product name, e.g. "ElectroBright RGBW Fixture".
  final String displayName;

  final IconData icon;

  /// BLE advertised-name prefixes this profile should match during scanning, e.g.
  /// ['ElectroBright_BLE', 'ElectroBright_RGBW_']. First match wins; keep prefixes disjoint
  /// across profiles in the catalog.
  final List<String> advertisedNamePrefixes;

  /// Exact strings this profile's firmware historically returned to a bare `INFO` command,
  /// for firmware shipped BEFORE the structured INFO reply (see §5.2). Kept forever for backward
  /// compatibility with fixtures that never get a firmware update.
  final List<String> legacyInfoIdentifiers;

  /// The structured model id new firmware reports, e.g. 'EB-C3-RGBW-V1'. Null for profiles that
  /// only ever shipped with legacy firmware.
  final String? structuredModelId;

  final String serviceUuid;
  final String rxCharacteristicUuid;
  final String txCharacteristicUuid;

  final int numModes;
  final int numPresets;
  final int minSpeed;
  final int maxSpeed;
  final int minFrequency;
  final int maxFrequency;
  final int maxBrightness;
  final int maxTimerMinutes;

  final bool supportsSound;
  final bool supportsSleep;
  final bool supportsTimer;
  final bool supportsFactoryReset;

  /// The per-mode capability table for this hardware — this is where today's global
  /// `ModeDefinition.allModes` list ends up living, scoped to the profile that actually has it.
  final List<ModeDefinition> modes;

  const DeviceProfile({
    required this.id,
    required this.displayName,
    required this.icon,
    required this.advertisedNamePrefixes,
    required this.legacyInfoIdentifiers,
    this.structuredModelId,
    required this.serviceUuid,
    required this.rxCharacteristicUuid,
    required this.txCharacteristicUuid,
    required this.numModes,
    required this.numPresets,
    required this.minSpeed,
    required this.maxSpeed,
    required this.minFrequency,
    required this.maxFrequency,
    required this.maxBrightness,
    required this.maxTimerMinutes,
    required this.modes,
    this.supportsSound = true,
    this.supportsSleep = true,
    this.supportsTimer = true,
    this.supportsFactoryReset = true,
  });

  ModeDefinition modeById(int modeId) =>
      modes.firstWhere((m) => m.id == modeId, orElse: () => modes.first);
}
