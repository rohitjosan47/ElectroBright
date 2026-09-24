import 'package:meta/meta.dart';

import 'channel_layout.dart';

/// How the app talks to a light.
enum DriverKind {
  /// ElectroBright firmware 3.x (text + binary protocol over Nordic UART).
  electroBright,

  /// A custom BLE profile (data-driven packet templates).
  profile,
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
    this.profileId,
    this.model,
    this.icon = 'bulb',
    this.whiteTempK = 4000,
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
  final String? profileId;

  /// Model id reported by the light (e.g. EB-C3-RGBW-V1).
  final String? model;
  final String icon;

  /// Colour temperature of the dedicated white LED (RGBW), in Kelvin.
  final int whiteTempK;
  final bool favourite;
  final DateTime addedAt;
  final DateTime? lastConnectedAt;

  static const Object _keep = Object();

  Fixture copyWith({
    String? deviceId,
    String? name,
    ChannelLayout? layout,
    DriverKind? driver,
    Object? profileId = _keep,
    Object? model = _keep,
    String? icon,
    int? whiteTempK,
    bool? favourite,
    Object? lastConnectedAt = _keep,
  }) => Fixture(
    id: id,
    deviceId: deviceId ?? this.deviceId,
    name: name ?? this.name,
    layout: layout ?? this.layout,
    driver: driver ?? this.driver,
    addedAt: addedAt,
    profileId: identical(profileId, _keep)
        ? this.profileId
        : profileId as String?,
    model: identical(model, _keep) ? this.model : model as String?,
    icon: icon ?? this.icon,
    whiteTempK: whiteTempK ?? this.whiteTempK,
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
    'profileId': profileId,
    'model': model,
    'icon': icon,
    'whiteTempK': whiteTempK,
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
    final Object? temp = json['whiteTempK'];
    return Fixture(
      id: id,
      deviceId: deviceId,
      name: name,
      layout: layout,
      driver: driver,
      addedAt: addedAt,
      profileId: json['profileId'] as String?,
      model: json['model'] as String?,
      icon: json['icon'] is String ? json['icon']! as String : 'bulb',
      whiteTempK: temp is int && temp >= 1500 && temp <= 10000 ? temp : 4000,
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
      other.profileId == profileId &&
      other.model == model &&
      other.icon == icon &&
      other.whiteTempK == whiteTempK &&
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
    profileId,
    model,
    icon,
    whiteTempK,
    favourite,
    addedAt,
    lastConnectedAt,
  );

  @override
  String toString() => 'Fixture($name, ${layout.wire}, $deviceId)';
}
