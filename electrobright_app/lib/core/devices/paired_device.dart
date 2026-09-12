import 'dart:convert';

class PairedDevice {
  /// Stable identity for this physical unit = the BLE transport's DiscoveredDevice.id
  /// (CoreBluetooth peripheral UUID on iOS, MAC address on Android). This is stable across
  /// app restarts for the same phone + same physical fixture, which is what lets "reconnect
  /// to my saved light" work without rescanning.
  final String id;

  /// Which DeviceCatalog entry this unit is. Resolved automatically during onboarding
  /// and overridable by the user via the device-type picker.
  final String profileId;

  /// User-given name, e.g. "Living Room Strip". Defaults to a suggested name at add-time.
  final String label;

  final DateTime addedAt;
  final DateTime? lastConnectedAt;

  const PairedDevice({
    required this.id,
    required this.profileId,
    required this.label,
    required this.addedAt,
    this.lastConnectedAt,
  });

  PairedDevice copyWith({
    String? profileId,
    String? label,
    DateTime? lastConnectedAt,
  }) =>
      PairedDevice(
        id: id,
        profileId: profileId ?? this.profileId,
        label: label ?? this.label,
        addedAt: addedAt,
        lastConnectedAt: lastConnectedAt ?? this.lastConnectedAt,
      );

  Map<String, dynamic> toMap() => {
        'id': id,
        'profileId': profileId,
        'label': label,
        'addedAt': addedAt.toIso8601String(),
        'lastConnectedAt': lastConnectedAt?.toIso8601String(),
      };

  factory PairedDevice.fromMap(Map<String, dynamic> map) => PairedDevice(
        id: map['id'] as String,
        profileId: map['profileId'] as String,
        label: map['label'] as String,
        addedAt: DateTime.tryParse(map['addedAt'] as String? ?? '') ?? DateTime.now(),
        lastConnectedAt: map['lastConnectedAt'] != null
            ? DateTime.tryParse(map['lastConnectedAt'] as String)
            : null,
      );

  String toJson() => jsonEncode(toMap());
  factory PairedDevice.fromJson(String s) => PairedDevice.fromMap(jsonDecode(s) as Map<String, dynamic>);
}
