import 'package:shared_preferences/shared_preferences.dart';
import 'paired_device.dart';

class DeviceLibraryRepository {
  static const String _libraryKey = 'electrobright_paired_devices_v1';
  static const String _activeDeviceKey = 'electrobright_active_device_id_v1';

  Future<List<PairedDevice>> loadDevices() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList(_libraryKey) ?? [];
      final result = <PairedDevice>[];
      for (final s in raw) {
        try {
          result.add(PairedDevice.fromJson(s));
        } catch (_) {
          // skip corrupted record
        }
      }
      return result;
    } catch (_) {
      return [];
    }
  }

  Future<void> saveDevices(List<PairedDevice> devices) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_libraryKey, devices.map((d) => d.toJson()).toList());
    } catch (_) {}
  }

  Future<String?> loadActiveDeviceId() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_activeDeviceKey);
    } catch (_) {
      return null;
    }
  }

  Future<void> saveActiveDeviceId(String? id) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (id == null) {
        await prefs.remove(_activeDeviceKey);
      } else {
        await prefs.setString(_activeDeviceKey, id);
      }
    } catch (_) {}
  }
}
