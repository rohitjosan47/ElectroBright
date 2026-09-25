import 'dart:convert';
import 'dart:io';

import 'package:electrobright/core/model/channel_layout.dart';
import 'package:electrobright/core/model/fixture.dart';
import 'package:electrobright/core/store/json_store.dart';
import 'package:electrobright/core/store/legacy_import.dart';
import 'package:flutter_test/flutter_test.dart';

final class _Prefs implements LegacyPrefs {
  _Prefs(this.values);
  final Map<String, Object> values;
  @override
  Set<String> getKeys() => values.keys.toSet();
  @override
  String? getString(String key) => values[key] as String?;
  @override
  List<String>? getStringList(String key) =>
      (values[key] as List<Object?>?)?.cast<String>();
}

/// Data shaped exactly like the previous app's SharedPreferences.
Map<String, Object> _oldAppData() => <String, Object>{
  'electrobright_paired_devices_v1': <String>[
    jsonEncode(<String, Object?>{
      'id': 'AA:BB:CC:DD:EE:01',
      'profileId': 'electrobright_c3_rgbw_v1',
      'label': 'Living Room',
      'addedAt': '2025-11-02T10:00:00.000',
      'lastConnectedAt': '2026-09-01T20:00:00.000',
    }),
    jsonEncode(<String, Object?>{
      'id': 'legacy-default',
      'profileId': 'electrobright_c3_rgbw_v1',
      'label': 'Default',
      'addedAt': '2025-01-01T00:00:00.000',
    }),
    jsonEncode(<String, Object?>{
      'id': 'XX',
      'profileId': 'generic_unverified',
      'label': 'Other',
      'addedAt': '2025-01-01T00:00:00.000',
    }),
    '{not json',
  ],
  'electrobright_preset_name_AA:BB:CC:DD:EE:01_0': 'Cozy Warmth',
  'electrobright_preset_name_AA:BB:CC:DD:EE:01_7': '  Cinema Night ',
  'electrobright_preset_data_AA:BB:CC:DD:EE:01_0': jsonEncode(<String, Object>{
    'red': 255,
    'green': 120,
    'blue': 20,
    'white': 40,
    'brightness': 200,
    'mode': 11,
    'modeSpeed': List<int>.filled(13, 5),
    'modeFrequency': List<int>.filled(13, 6),
    'fireworkColorMode': 0,
    'clubColorMode': 1,
    'policeColorMode': 1,
    'policeColorAR': 255,
    'policeColorAG': 165,
    'policeColorAB': 0,
    'policeColorAW': 0,
    'policeColorBR': 0,
    'policeColorBG': 0,
    'policeColorBB': 0,
    'policeColorBW': 255,
  }),
  'electrobright_preset_data_AA:BB:CC:DD:EE:01_3': '{"red": 999}',
};

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('eb-import'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('imports the lights once, never their presets', () async {
    final JsonStore store = await JsonStore.open(dir);
    final List<Fixture> added = <Fixture>[];
    int n = 0;
    final LegacyImportResult? r = LegacyImport.run(
      prefs: _Prefs(_oldAppData()),
      store: store,
      existing: const <Fixture>[],
      addFixture: added.add,
      newId: () => 'f${n++}',
    );
    expect(r, (lights: 1));
    expect(added.single.name, 'Living Room');
    expect(added.single.deviceId, 'AA:BB:CC:DD:EE:01');
    expect(added.single.layout, ChannelLayout.rgbw);
    expect(added.single.identity!.assumed, isTrue);

    // The old app's preset names and snapshots are left behind: firmware
    // 3.6.0 clears the presets on the lights.
    expect(store.read('presetMeta'), isNull);

    // Idempotent.
    expect(
      LegacyImport.run(
        prefs: _Prefs(_oldAppData()),
        store: store,
        existing: added,
        addFixture: added.add,
        newId: () => 'again',
      ),
      isNull,
    );
    expect(added, hasLength(1));
  });

  test('lights already saved are not duplicated', () async {
    final JsonStore store = await JsonStore.open(dir);
    final Fixture mine = Fixture(
      id: 'x',
      deviceId: 'AA:BB:CC:DD:EE:01',
      name: 'Mine',
      layout: ChannelLayout.cct,
      driver: DriverKind.electroBright,
      addedAt: DateTime(2026),
    );
    final List<Fixture> added = <Fixture>[];
    final LegacyImportResult? r = LegacyImport.run(
      prefs: _Prefs(_oldAppData()),
      store: store,
      existing: <Fixture>[mine],
      addFixture: added.add,
      newId: () => 'y',
    );
    expect(r!.lights, 0);
    expect(added, isEmpty);
  });
}
