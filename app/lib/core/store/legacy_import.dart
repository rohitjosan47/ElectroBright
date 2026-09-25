import 'dart:convert';

import '../model/channel_layout.dart';
import '../model/fixture.dart';
import '../protocol/eb/eb_fixture_catalog.dart';
import 'json_store.dart';

/// Read-only view of the previous app's SharedPreferences (the legacy,
/// synchronous API: on Android the newer async API reads a different store).
abstract interface class LegacyPrefs {
  Set<String> getKeys();
  String? getString(String key);
  List<String>? getStringList(String key);
}

/// What the one-time import found.
typedef LegacyImportResult = ({int lights});

/// One-time, non-destructive import of the previous app's saved lights (plan
/// §13), as RGBW, the only fixture that app knew; the first connection
/// confirms or corrects the type. Its presets are not imported: firmware
/// 3.6.0 clears the presets on the lights. Old keys are never deleted;
/// running it again does nothing.
abstract final class LegacyImport {
  static const String doneFlag = 'legacyImportDone';
  static const String pairedKey = 'electrobright_paired_devices_v1';

  /// Imports into [store] unless already done. [existing] are the lights
  /// already saved (never duplicated). Returns null when skipped.
  static LegacyImportResult? run({
    required LegacyPrefs prefs,
    required JsonStore store,
    required List<Fixture> existing,
    required void Function(Fixture f) addFixture,
    required String Function() newId,
  }) {
    final Map<String, Object?> settings = _map(store.read('settings'));
    if (settings[doneFlag] == true) return null;

    int lights = 0;
    final Set<String> knownDevices = existing
        .map((Fixture f) => f.deviceId)
        .toSet();

    for (final String raw in prefs.getStringList(pairedKey) ?? <String>[]) {
      final Map<String, Object?>? d = _decode(raw);
      final Object? deviceId = d?['id'];
      final Object? label = d?['label'];
      final Object? profile = d?['profileId'];
      if (deviceId is! String ||
          deviceId.isEmpty ||
          deviceId == 'legacy-default') {
        continue;
      }
      if (profile == 'generic_unverified' || knownDevices.contains(deviceId)) {
        continue;
      }
      final Fixture f = Fixture(
        id: newId(),
        deviceId: deviceId,
        name: label is String && label.trim().isNotEmpty
            ? label.trim()
            : 'ElectroBright light',
        layout: ChannelLayout.rgbw,
        driver: DriverKind.electroBright,
        addedAt: DateTime.tryParse('${d?['addedAt']}') ?? DateTime.now(),
        whitePoints: EbFixtureCatalog.whitePointsFor(
          layout: ChannelLayout.rgbw,
        ),
        identity: FixtureIdentity.assumed(ChannelLayout.rgbw),
        lastConnectedAt: DateTime.tryParse('${d?['lastConnectedAt']}'),
      );
      addFixture(f);
      knownDevices.add(deviceId);
      lights++;
    }

    settings[doneFlag] = true;
    store.write('settings', settings);
    return (lights: lights);
  }

  static Map<String, Object?>? _decode(String? raw) {
    if (raw == null) return null;
    try {
      final Object? v = jsonDecode(raw);
      return v is Map<String, Object?> ? v : null;
    } on FormatException {
      return null;
    }
  }

  static Map<String, Object?> _map(Object? v) => v is Map<String, Object?>
      ? Map<String, Object?>.of(v)
      : <String, Object?>{};
}
