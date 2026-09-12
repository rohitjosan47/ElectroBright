import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/devices/paired_device.dart';
import '../../../core/devices/device_library_repository.dart';
import '../../../core/devices/device_profile.dart';
import '../../../core/devices/device_catalog.dart';
import '../../presets/data/preset_name_repository.dart';

class DeviceLibraryState {
  final List<PairedDevice> devices;
  final String? activeDeviceId;
  final bool loaded;

  const DeviceLibraryState({
    required this.devices,
    required this.activeDeviceId,
    required this.loaded,
  });

  factory DeviceLibraryState.initial() =>
      const DeviceLibraryState(devices: [], activeDeviceId: null, loaded: false);

  PairedDevice? get activeDevice {
    if (activeDeviceId == null) return null;
    for (final d in devices) {
      if (d.id == activeDeviceId) return d;
    }
    return null;
  }

  DeviceProfile get activeProfile {
    final d = activeDevice;
    return d != null ? DeviceCatalog.getById(d.profileId) : DeviceCatalog.electrobrightC3RgbwV1;
  }

  DeviceLibraryState copyWith({
    List<PairedDevice>? devices,
    String? activeDeviceId,
    bool clearActiveDeviceId = false,
    bool? loaded,
  }) =>
      DeviceLibraryState(
        devices: devices ?? this.devices,
        activeDeviceId: clearActiveDeviceId ? null : (activeDeviceId ?? this.activeDeviceId),
        loaded: loaded ?? this.loaded,
      );
}

final deviceLibraryRepositoryProvider = Provider((ref) => DeviceLibraryRepository());

final deviceLibraryProvider =
    StateNotifierProvider<DeviceLibraryNotifier, DeviceLibraryState>((ref) {
  return DeviceLibraryNotifier(ref.watch(deviceLibraryRepositoryProvider));
});

class DeviceLibraryNotifier extends StateNotifier<DeviceLibraryState> {
  final DeviceLibraryRepository _repo;

  DeviceLibraryNotifier(this._repo) : super(DeviceLibraryState.initial()) {
    _load();
  }

  Future<void> _load() async {
    final devices = await _repo.loadDevices();
    final activeId = await _repo.loadActiveDeviceId();
    final resolvedActive =
        devices.any((d) => d.id == activeId) ? activeId : (devices.isNotEmpty ? devices.first.id : null);
    state = state.copyWith(devices: devices, activeDeviceId: resolvedActive, loaded: true);
  }

  Future<void> addDevice(PairedDevice device) async {
    final updated = [...state.devices, device];
    state = state.copyWith(devices: updated, activeDeviceId: device.id);
    await _repo.saveDevices(updated);
    await _repo.saveActiveDeviceId(device.id);
  }

  Future<void> renameDevice(String id, String newLabel) async {
    final clean = newLabel.trim();
    if (clean.isEmpty) return;
    final updated = state.devices.map((d) => d.id == id ? d.copyWith(label: clean) : d).toList();
    state = state.copyWith(devices: updated);
    await _repo.saveDevices(updated);
  }

  Future<void> retypeDevice(String id, String newProfileId) async {
    final updated = state.devices.map((d) => d.id == id ? d.copyWith(profileId: newProfileId) : d).toList();
    state = state.copyWith(devices: updated);
    await _repo.saveDevices(updated);
  }

  Future<void> touchLastConnected(String id) async {
    final updated =
        state.devices.map((d) => d.id == id ? d.copyWith(lastConnectedAt: DateTime.now()) : d).toList();
    state = state.copyWith(devices: updated);
    await _repo.saveDevices(updated);
  }

  Future<void> removeDevice(String id, int numPresets) async {
    final updated = state.devices.where((d) => d.id != id).toList();
    final wasActive = state.activeDeviceId == id;
    state = state.copyWith(
      devices: updated,
      activeDeviceId: wasActive ? (updated.isNotEmpty ? updated.first.id : null) : null,
      clearActiveDeviceId: wasActive && updated.isEmpty,
    );
    await _repo.saveDevices(updated);
    await _repo.saveActiveDeviceId(state.activeDeviceId);
    
    // Clear namespaced preset storage for this device
    final repo = PresetNameRepository(id, numPresets);
    await repo.wipeAll();
  }

  Future<void> setActiveDevice(String id) async {
    if (!state.devices.any((d) => d.id == id)) return;
    state = state.copyWith(activeDeviceId: id);
    await _repo.saveActiveDeviceId(id);
  }
}
