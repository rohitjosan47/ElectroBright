import '../drivers/electrobright/eb_types.dart';
import '../core/protocol/eb/eb_scene.dart';

/// Last-known state of a light, saved so screens render at once (and while
/// the light is away). The sleep timer is never saved (it runs on the light).
abstract final class DeviceStateJson {
  static Map<String, Object?> toJson(EbDeviceState s) => <String, Object?>{
    'scene': s.scene.toJson(),
    'sleeping': s.sleeping,
    'soundOn': s.soundOn,
    'presets': s.presets.toList()..sort(),
  };

  static EbDeviceState? fromJson(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final EbScene? scene = EbScene.fromJson(json['scene']);
    final Object? presets = json['presets'];
    if (scene == null || presets is! List<Object?>) return null;
    if (presets.any((Object? p) => p is! int || p < 0 || p > 31)) return null;
    return EbDeviceState(
      scene: scene,
      sleeping: json['sleeping'] == true,
      soundOn: json['soundOn'] != false,
      presets: presets.cast<int>().toSet(),
    );
  }
}
