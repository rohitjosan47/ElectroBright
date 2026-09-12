import 'package:shared_preferences/shared_preferences.dart';
import 'paired_device.dart';
import 'device_catalog.dart';

class LegacyMigrationService {
  static Future<void> run() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool('electrobright_migration_v1_done') == true) return;
      
      final rawDevices = prefs.getStringList('electrobright_paired_devices_v1') ?? [];
      if (rawDevices.isNotEmpty) {
        await prefs.setBool('electrobright_migration_v1_done', true);
        return;
      }
      
      bool hasLegacy = false;
      final legacyPresetCount = DeviceCatalog.electrobrightC3RgbwV1.numPresets;
      for (int i = 0; i < legacyPresetCount; i++) {
        if (prefs.containsKey('electrobright_preset_name_$i') || 
            prefs.containsKey('electrobright_preset_data_$i')) {
          hasLegacy = true;
          break;
        }
      }
      if (prefs.containsKey('electrobright_saved_preset_ids')) {
        hasLegacy = true;
      }
      
      if (!hasLegacy) {
        await prefs.setBool('electrobright_migration_v1_done', true);
        return;
      }
      
      const deviceId = 'legacy-default';
      for (int i = 0; i < legacyPresetCount; i++) {
        final nameKey = 'electrobright_preset_name_$i';
        if (prefs.containsKey(nameKey)) {
          await prefs.setString('electrobright_preset_name_${deviceId}_$i', prefs.getString(nameKey)!);
        }
        final dataKey = 'electrobright_preset_data_$i';
        if (prefs.containsKey(dataKey)) {
          await prefs.setString('electrobright_preset_data_${deviceId}_$i', prefs.getString(dataKey)!);
        }
      }
      if (prefs.containsKey('electrobright_saved_preset_ids')) {
        await prefs.setStringList('electrobright_saved_preset_ids_$deviceId', prefs.getStringList('electrobright_saved_preset_ids')!);
      }
      
      final pairedDevice = PairedDevice(
        id: deviceId,
        profileId: DeviceCatalog.electrobrightC3RgbwV1.id,
        label: 'My ElectroBright Light',
        addedAt: DateTime.now(),
      );
      
      await prefs.setStringList('electrobright_paired_devices_v1', [pairedDevice.toJson()]);
      await prefs.setString('electrobright_active_device_id_v1', deviceId);
      
      await prefs.setBool('electrobright_migration_v1_done', true);
    } catch (_) {}
  }
}
