import 'dart:convert';

import '../model/channel_color.dart';
import '../model/channel_layout.dart';
import '../model/fixture.dart';
import '../protocol/eb/eb_constants.dart';
import '../protocol/eb/eb_fixture_catalog.dart';
import '../protocol/eb/eb_scene.dart';
import 'json_store.dart';

/// Read-only view of the previous app's SharedPreferences (the legacy,
/// synchronous API: on Android the newer async API reads a different store).
abstract interface class LegacyPrefs {
  Set<String> getKeys();
  String? getString(String key);
  List<String>? getStringList(String key);
}

/// What the one-time import found.
typedef LegacyImportResult = ({int lights, int presetNames, int presetScenes});

/// One-time, non-destructive import of the previous app's data (plan §13):
/// saved lights (as RGBW, the only fixture that app knew; the first
/// connection confirms or corrects the type), preset names and preset
/// snapshots. Old keys are never deleted; running it again does nothing.
abstract final class LegacyImport {
  static const String doneFlag = 'legacyImportDone';
  static const String pairedKey = 'electrobright_paired_devices_v1';
  static const String namePrefix = 'electrobright_preset_name_';
  static const String dataPrefix = 'electrobright_preset_data_';

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

    int lights = 0, names = 0, scenes = 0;
    final Map<String, Object?> presetMeta = _map(store.read('presetMeta'));
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

      final Map<String, Object?> slots = <String, Object?>{};
      for (int slot = 0; slot < Eb.numPresets; slot++) {
        final Map<String, Object?> entry = <String, Object?>{};
        final String? name = prefs.getString('$namePrefix${deviceId}_$slot');
        if (name != null && name.trim().isNotEmpty) {
          entry['name'] = name.trim();
          names++;
        }
        final EbScene? scene = _scene(
          prefs.getString('$dataPrefix${deviceId}_$slot'),
        );
        if (scene != null) {
          entry['scene'] = scene.toJson();
          entry['assumedLayout'] = true;
          scenes++;
        }
        if (entry.isNotEmpty) slots['$slot'] = entry;
      }
      if (slots.isNotEmpty) presetMeta[f.id] = slots;
    }

    if (presetMeta.isNotEmpty) store.write('presetMeta', presetMeta);
    settings[doneFlag] = true;
    store.write('settings', settings);
    return (lights: lights, presetNames: names, presetScenes: scenes);
  }

  /// The old app's PresetData JSON (RGBW fields) as a scene.
  static EbScene? _scene(String? raw) {
    final Map<String, Object?>? m = _decode(raw);
    if (m == null) return null;
    int? byte(String k) {
      final Object? v = m[k];
      return v is int && v >= 0 && v <= 255 ? v : null;
    }

    List<int>? levels(String k) {
      final Object? v = m[k];
      if (v is! List<Object?> || v.length != Eb.numModes) return null;
      if (v.any(
        (Object? e) => e is! int || e < Eb.minLevel || e > Eb.maxLevel,
      )) {
        return null;
      }
      return v.cast<int>();
    }

    ChannelColor? rgbw(String r, String g, String b, String w) {
      final List<int?> v = <int?>[byte(r), byte(g), byte(b), byte(w)];
      return v.contains(null)
          ? null
          : ChannelColor(ChannelLayout.rgbw, v.cast<int>());
    }

    final ChannelColor? color = rgbw('red', 'green', 'blue', 'white');
    final ChannelColor? a = rgbw(
      'policeColorAR',
      'policeColorAG',
      'policeColorAB',
      'policeColorAW',
    );
    final ChannelColor? b = rgbw(
      'policeColorBR',
      'policeColorBG',
      'policeColorBB',
      'policeColorBW',
    );
    final int? brightness = byte('brightness');
    final int? mode = byte('mode');
    final List<int>? speeds = levels('modeSpeed');
    final List<int>? freqs = levels('modeFrequency');
    final int? fw = byte('fireworkColorMode');
    final int? club = byte('clubColorMode');
    final int? police = byte('policeColorMode');
    if (color == null ||
        a == null ||
        b == null ||
        brightness == null ||
        mode == null ||
        mode < 1 ||
        mode > Eb.numModes ||
        speeds == null ||
        freqs == null ||
        fw == null ||
        fw > 1 ||
        club == null ||
        club > 1 ||
        police == null ||
        police > 1) {
      return null;
    }
    return EbScene(
      color: color,
      brightness: brightness,
      mode: mode,
      speeds: speeds,
      frequencies: freqs,
      fireworkColorMode: fw,
      clubColorMode: club,
      policeColorMode: police,
      policeA: a,
      policeB: b,
    );
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
