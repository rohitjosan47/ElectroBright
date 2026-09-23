import 'dart:convert';
import '../../../core/devices/device_catalog.dart';

/// Immutable snapshot representing the complete parameter state of a saved preset scene.
class PresetData {
  final int red;
  final int green;
  final int blue;
  final int white;
  final int brightness;
  final int mode;
  final List<int> modeSpeed;
  final List<int> modeFrequency;
  final int fireworkColorMode;
  final int clubColorMode;
  final int policeColorMode;
  final int policeColorAR;
  final int policeColorAG;
  final int policeColorAB;
  final int policeColorAW;
  final int policeColorBR;
  final int policeColorBG;
  final int policeColorBB;
  final int policeColorBW;

  const PresetData({
    required this.red,
    required this.green,
    required this.blue,
    required this.white,
    required this.brightness,
    required this.mode,
    required this.modeSpeed,
    required this.modeFrequency,
    this.fireworkColorMode = 0,
    this.clubColorMode = 0,
    this.policeColorMode = 1,
    // Defaults match the firmware's setDefaultState().
    this.policeColorAR = 255,
    this.policeColorAG = 165,
    this.policeColorAB = 0,
    this.policeColorAW = 0,
    this.policeColorBR = 0,
    this.policeColorBG = 0,
    this.policeColorBB = 0,
    this.policeColorBW = 255,
  });

  factory PresetData.fromValues({
    required int red,
    required int green,
    required int blue,
    required int white,
    required int brightness,
    required int mode,
    required List<int> modeSpeed,
    required List<int> modeFrequency,
    required int fireworkColorMode,
    required int clubColorMode,
    required int policeColorMode,
    required int policeColorAR,
    required int policeColorAG,
    required int policeColorAB,
    required int policeColorAW,
    required int policeColorBR,
    required int policeColorBG,
    required int policeColorBB,
    required int policeColorBW,
  }) {
    return PresetData(
      red: red,
      green: green,
      blue: blue,
      white: white,
      brightness: brightness,
      mode: mode,
      modeSpeed: List<int>.from(modeSpeed),
      modeFrequency: List<int>.from(modeFrequency),
      fireworkColorMode: fireworkColorMode,
      clubColorMode: clubColorMode,
      policeColorMode: policeColorMode,
      policeColorAR: policeColorAR,
      policeColorAG: policeColorAG,
      policeColorAB: policeColorAB,
      policeColorAW: policeColorAW,
      policeColorBR: policeColorBR,
      policeColorBG: policeColorBG,
      policeColorBB: policeColorBB,
      policeColorBW: policeColorBW,
    );
  }

  Map<String, dynamic> toMap() => {
        'red': red,
        'green': green,
        'blue': blue,
        'white': white,
        'brightness': brightness,
        'mode': mode,
        'modeSpeed': modeSpeed,
        'modeFrequency': modeFrequency,
        'fireworkColorMode': fireworkColorMode,
        'clubColorMode': clubColorMode,
        'policeColorMode': policeColorMode,
        'policeColorAR': policeColorAR,
        'policeColorAG': policeColorAG,
        'policeColorAB': policeColorAB,
        'policeColorAW': policeColorAW,
        'policeColorBR': policeColorBR,
        'policeColorBG': policeColorBG,
        'policeColorBB': policeColorBB,
        'policeColorBW': policeColorBW,
      };

  String toJson() => jsonEncode(toMap());

  factory PresetData.fromMap(Map<String, dynamic> map) {
    return PresetData(
      red: map['red'] as int? ?? 255,
      green: map['green'] as int? ?? 255,
      blue: map['blue'] as int? ?? 255,
      white: map['white'] as int? ?? 0,
      brightness: map['brightness'] as int? ?? 255,
      mode: map['mode'] as int? ?? 1,
      modeSpeed: (map['modeSpeed'] as List<dynamic>?)?.map((e) => e as int).toList() ??
          List.filled(DeviceCatalog.electrobrightC3RgbwV1.numModes, 5),
      modeFrequency: (map['modeFrequency'] as List<dynamic>?)?.map((e) => e as int).toList() ??
          List.filled(DeviceCatalog.electrobrightC3RgbwV1.numModes, 5),
      fireworkColorMode: map['fireworkColorMode'] as int? ?? 0,
      clubColorMode: map['clubColorMode'] as int? ?? 0,
      policeColorMode: map['policeColorMode'] as int? ?? 1,
      policeColorAR: map['policeColorAR'] as int? ?? 255,
      policeColorAG: map['policeColorAG'] as int? ?? 165,
      policeColorAB: map['policeColorAB'] as int? ?? 0,
      policeColorAW: map['policeColorAW'] as int? ?? 0,
      policeColorBR: map['policeColorBR'] as int? ?? 0,
      policeColorBG: map['policeColorBG'] as int? ?? 0,
      policeColorBB: map['policeColorBB'] as int? ?? 0,
      policeColorBW: map['policeColorBW'] as int? ?? 255,
    );
  }

  factory PresetData.fromJson(String source) =>
      PresetData.fromMap(jsonDecode(source) as Map<String, dynamic>);
}
