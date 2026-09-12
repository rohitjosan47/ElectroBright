import 'package:shared_preferences/shared_preferences.dart';
import '../domain/preset_data.dart';

/// Repository managing persistent storage of custom preset names and preset data snapshots.
class PresetNameRepository {
  final String deviceId;
  final int numPresets;
  
  const PresetNameRepository(this.deviceId, this.numPresets);

  String get _nameKeyPrefix => 'electrobright_preset_name_${deviceId}_';
  String get _dataKeyPrefix => 'electrobright_preset_data_${deviceId}_';
  String get _savedIdsKey => 'electrobright_saved_preset_ids_$deviceId';

  Future<Map<int, String>> loadPresetNames() async {
    final Map<int, String> names = {};
    try {
      final prefs = await SharedPreferences.getInstance();
      for (int i = 0; i < numPresets; i++) {
        final saved = prefs.getString('$_nameKeyPrefix$i');
        if (saved != null && saved.trim().isNotEmpty) {
          names[i] = saved.trim();
        }
      }
    } catch (_) {}
    return names;
  }

  Future<void> savePresetName(int slotId, String name) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final clean = name.trim();
      if (clean.isNotEmpty) {
        await prefs.setString('$_nameKeyPrefix$slotId', clean);
      } else {
        await prefs.remove('$_nameKeyPrefix$slotId');
      }
    } catch (_) {}
  }

  Future<void> resetPresetName(int slotId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('$_nameKeyPrefix$slotId');
    } catch (_) {}
  }

  Future<Map<int, PresetData>> loadPresetSnapshots() async {
    final Map<int, PresetData> snapshots = {};
    try {
      final prefs = await SharedPreferences.getInstance();
      for (int i = 0; i < numPresets; i++) {
        final jsonStr = prefs.getString('$_dataKeyPrefix$i');
        if (jsonStr != null && jsonStr.isNotEmpty) {
          try {
            snapshots[i] = PresetData.fromJson(jsonStr);
          } catch (_) {}
        }
      }
    } catch (_) {}
    return snapshots;
  }

  Future<void> savePresetSnapshot(int slotId, PresetData snapshot) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('$_dataKeyPrefix$slotId', snapshot.toJson());
    } catch (_) {}
  }

  Future<void> deletePresetSnapshot(int slotId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('$_dataKeyPrefix$slotId');
    } catch (_) {}
  }

  Future<Set<int>?> loadSavedPresetIds() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = prefs.getStringList(_savedIdsKey);
      if (list != null) {
        return list.map((e) => int.tryParse(e)).whereType<int>().toSet();
      }
    } catch (_) {}
    return null;
  }

  Future<void> saveSavedPresetIds(Set<int> ids) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
        _savedIdsKey,
        ids.map((id) => id.toString()).toList(),
      );
    } catch (_) {}
  }

  Future<void> wipeAll() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      for (int i = 0; i < numPresets; i++) {
        await prefs.remove('$_nameKeyPrefix$i');
        await prefs.remove('$_dataKeyPrefix$i');
      }
      await prefs.remove(_savedIdsKey);
    } catch (_) {}
  }
}
