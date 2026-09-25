import 'package:meta/meta.dart';

import '../color/led_white_points.dart';
import 'channel_layout.dart';
import 'light_capabilities.dart';

/// How the app talks to a light.
enum DriverKind {
  /// ElectroBright firmware 3.x (text + binary protocol over Nordic UART).
  electroBright,

  /// A custom BLE profile (data-driven packet templates).
  profile,
}

/// What the light's firmware said about itself the last time it connected.
@immutable
final class FixtureIdentity {
  const FixtureIdentity({
    required this.capabilities,
    this.model,
    this.firmwareVersion,
    this.caps,
    this.learnedAt,
    this.assumed = false,
  });

  /// Not read from the light yet (from its BLE name or an imported record).
  factory FixtureIdentity.assumed(ChannelLayout layout) => FixtureIdentity(
    capabilities: LightCapabilities.assumed(layout),
    assumed: true,
  );

  final LightCapabilities capabilities;

  /// INFO model id, e.g. EB-C3-RGBCCT-V1.
  final String? model;

  /// VERSION, e.g. 3.5.0.
  final String? firmwareVersion;

  /// The raw CAPS reply (shown in "What this light can do").
  final String? caps;
  final DateTime? learnedAt;
  final bool assumed;

  Map<String, Object?> toJson() => <String, Object?>{
    'capabilities': capabilities.toJson(),
    'model': model,
    'firmwareVersion': firmwareVersion,
    'caps': caps,
    'learnedAt': learnedAt?.toUtc().toIso8601String(),
    'assumed': assumed,
  };

  static FixtureIdentity? fromJson(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final LightCapabilities? caps = LightCapabilities.fromJson(
      json['capabilities'],
    );
    if (caps == null) return null;
    String? str(String k) => json[k] is String ? json[k]! as String : null;
    return FixtureIdentity(
      capabilities: caps,
      model: str('model'),
      firmwareVersion: str('firmwareVersion'),
      caps: str('caps'),
      learnedAt: json['learnedAt'] == null
          ? null
          : DateTime.tryParse('${json['learnedAt']}'),
      assumed: json['assumed'] == true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is FixtureIdentity &&
      other.capabilities == capabilities &&
      other.model == model &&
      other.firmwareVersion == firmwareVersion &&
      other.caps == caps &&
      other.learnedAt == learnedAt &&
      other.assumed == assumed;

  @override
  int get hashCode => Object.hash(
    capabilities,
    model,
    firmwareVersion,
    caps,
    learnedAt,
    assumed,
  );
}

/// A saved light.
@immutable
final class Fixture {
  const Fixture({
    required this.id,
    required this.deviceId,
    required this.name,
    required this.layout,
    required this.driver,
    required this.addedAt,
    this.identity,
    this.whitePoints = const LedWhitePoints(),
    this.profileId,
    this.icon = 'bulb',
    this.favourite = false,
    this.lastConnectedAt,
  });

  /// App-level id (stable across re-links).
  final String id;

  /// Platform peripheral id (iOS UUID / Android MAC); changes on a new phone.
  final String deviceId;
  final String name;

  /// The light's channel layout (confirmed by its firmware on every connect).
  final ChannelLayout layout;
  final DriverKind driver;

  /// What the firmware reported (null until the first connection).
  final FixtureIdentity? identity;

  /// Colour temperatures of the light's white LEDs, from the fixture catalog
  /// (set when the light is added, corrected on every connect).
  final LedWhitePoints whitePoints;
  final String? profileId;
  final String icon;
  final bool favourite;
  final DateTime addedAt;
  final DateTime? lastConnectedAt;

  /// What the light can do: learned from its firmware, else assumed.
  LightCapabilities get capabilities =>
      identity?.capabilities ?? LightCapabilities.assumed(layout);

  static const Object _keep = Object();

  Fixture copyWith({
    String? deviceId,
    String? name,
    ChannelLayout? layout,
    DriverKind? driver,
    Object? identity = _keep,
    LedWhitePoints? whitePoints,
    Object? profileId = _keep,
    String? icon,
    bool? favourite,
    Object? lastConnectedAt = _keep,
  }) => Fixture(
    id: id,
    deviceId: deviceId ?? this.deviceId,
    name: name ?? this.name,
    layout: layout ?? this.layout,
    driver: driver ?? this.driver,
    addedAt: addedAt,
    identity: identical(identity, _keep)
        ? this.identity
        : identity as FixtureIdentity?,
    whitePoints: whitePoints ?? this.whitePoints,
    profileId: identical(profileId, _keep)
        ? this.profileId
        : profileId as String?,
    icon: icon ?? this.icon,
    favourite: favourite ?? this.favourite,
    lastConnectedAt: identical(lastConnectedAt, _keep)
        ? this.lastConnectedAt
        : lastConnectedAt as DateTime?,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'deviceId': deviceId,
    'name': name,
    'layout': layout.wire,
    'driver': driver.name,
    'identity': identity?.toJson(),
    'whitePoints': whitePoints.toJson(),
    'profileId': profileId,
    'icon': icon,
    'favourite': favourite,
    'addedAt': addedAt.toUtc().toIso8601String(),
    'lastConnectedAt': lastConnectedAt?.toUtc().toIso8601String(),
  };

  /// Strict: null when required fields are missing or invalid.
  static Fixture? fromJson(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final Object? id = json['id'];
    final Object? deviceId = json['deviceId'];
    final Object? name = json['name'];
    final ChannelLayout? layout = json['layout'] is String
        ? ChannelLayout.fromWire(json['layout']! as String)
        : null;
    final DriverKind? driver = DriverKind.values
        .where((DriverKind d) => d.name == json['driver'])
        .firstOrNull;
    final DateTime? addedAt = DateTime.tryParse('${json['addedAt']}');
    if (id is! String ||
        id.isEmpty ||
        deviceId is! String ||
        deviceId.isEmpty ||
        name is! String ||
        layout == null ||
        driver == null ||
        addedAt == null) {
      return null;
    }
    FixtureIdentity? identity = FixtureIdentity.fromJson(json['identity']);
    if (identity != null && identity.capabilities.layout != layout) {
      identity = null; // inconsistent record: relearn on the next connect
    }
    return Fixture(
      id: id,
      deviceId: deviceId,
      name: name,
      layout: layout,
      driver: driver,
      addedAt: addedAt,
      identity: identity,
      whitePoints: LedWhitePoints.fromJson(json['whitePoints']),
      profileId: json['profileId'] as String?,
      icon: json['icon'] is String ? json['icon']! as String : 'bulb',
      favourite: json['favourite'] == true,
      lastConnectedAt: json['lastConnectedAt'] == null
          ? null
          : DateTime.tryParse('${json['lastConnectedAt']}'),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Fixture &&
      other.id == id &&
      other.deviceId == deviceId &&
      other.name == name &&
      other.layout == layout &&
      other.driver == driver &&
      other.identity == identity &&
      other.whitePoints == whitePoints &&
      other.profileId == profileId &&
      other.icon == icon &&
      other.favourite == favourite &&
      other.addedAt == addedAt &&
      other.lastConnectedAt == lastConnectedAt;

  @override
  int get hashCode => Object.hash(
    id,
    deviceId,
    name,
    layout,
    driver,
    identity,
    whitePoints,
    profileId,
    icon,
    favourite,
    addedAt,
    lastConnectedAt,
  );

  @override
  String toString() => 'Fixture($name, ${layout.wire}, $deviceId)';
}
