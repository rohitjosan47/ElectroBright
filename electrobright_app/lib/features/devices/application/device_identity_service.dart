import 'dart:async';
import '../../../core/ble/ble_transport.dart';
import '../../../core/ble/ble_protocol.dart';
import '../../../core/devices/device_profile.dart';
import '../../../core/devices/device_catalog.dart';

class DeviceIdentityResult {
  final DeviceProfile profile;
  final bool wasPositivelyIdentified; // false => generic fallback was used
  const DeviceIdentityResult(this.profile, this.wasPositivelyIdentified);
}

class DeviceIdentityService {
  /// Call AFTER transport.connect(id) has returned true. [advertisedName] is the name
  /// captured during scanning (DiscoveredDevice.name), used as a fallback signal.
  static Future<DeviceIdentityResult> identify(
    BleTransport transport,
    String advertisedName,
  ) async {
    final completer = Completer<String?>();
    late final StreamSubscription sub;
    sub = transport.notificationsStream.listen((line) {
      if (line.trim().startsWith('INFO:') && !completer.isCompleted) {
        completer.complete(line.trim());
      }
    });

    await transport.sendRaw(BleProtocol.getInfo());
    final infoLine = await completer.future.timeout(
      const Duration(milliseconds: 2500),
      onTimeout: () => null,
    );
    await sub.cancel();

    if (infoLine != null) {
      final resolved = _resolveFromInfo(infoLine);
      if (resolved != null) return DeviceIdentityResult(resolved, true);
    }

    final byName = _resolveFromAdvertisedName(advertisedName);
    if (byName != null) return DeviceIdentityResult(byName, true);

    return DeviceIdentityResult(DeviceCatalog.genericFallbackProfile(advertisedName), false);
  }

  static DeviceProfile? _resolveFromInfo(String infoLine) {
    final value = BleProtocol.parseInfoValue(infoLine);
    if (value == null || value.isEmpty) return null;
    for (final p in DeviceCatalog.allProfiles) {
      if (p.structuredModelId != null && p.structuredModelId == value) return p;
      if (p.legacyInfoIdentifiers.contains(value)) return p;
    }
    return null;
  }

  static DeviceProfile? _resolveFromAdvertisedName(String name) {
    if (name.isEmpty) return null;
    for (final p in DeviceCatalog.allProfiles) {
      for (final prefix in p.advertisedNamePrefixes) {
        if (name.startsWith(prefix)) return p;
      }
    }
    return null;
  }
}
