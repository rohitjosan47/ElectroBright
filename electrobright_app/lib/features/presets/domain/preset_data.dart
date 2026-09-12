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
    this.policeColorAR = 255,
    this.policeColorAG = 0,
    this.policeColorAB = 0,
    this.policeColorAW = 0,
    this.policeColorBR = 0,
    this.policeColorBG = 0,
    this.policeColorBB = 255,
    this.policeColorBW = 0,
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
      policeColorAG: map['policeColorAG'] as int? ?? 0,
      policeColorAB: map['policeColorAB'] as int? ?? 0,
      policeColorAW: map['policeColorAW'] as int? ?? 0,
      policeColorBR: map['policeColorBR'] as int? ?? 0,
      policeColorBG: map['policeColorBG'] as int? ?? 0,
      policeColorBB: map['policeColorBB'] as int? ?? 255,
      policeColorBW: map['policeColorBW'] as int? ?? 0,
    );
  }

  factory PresetData.fromJson(String source) =>
      PresetData.fromMap(jsonDecode(source) as Map<String, dynamic>);

  /// Curated factory default presets for slots 0..4 offering instant visual diversity out-of-the-box.
  static Map<int, PresetData> defaultPresets() {
    final defaultSpeeds = List<int>.filled(DeviceCatalog.electrobrightC3RgbwV1.numModes, 5);
    final defaultFreqs = List<int>.filled(DeviceCatalog.electrobrightC3RgbwV1.numModes, 5);

    // Preset 1 (Slot 0): Cozy Warm Candle
    final candleSpeeds = List<int>.from(defaultSpeeds);
    final candleFreqs = List<int>.from(defaultFreqs);
    candleSpeeds[12] = 6; // Mode 13
    candleFreqs[12] = 7;

    // Preset 2 (Slot 1): Cyber Club Neon
    final clubSpeeds = List<int>.from(defaultSpeeds);
    final clubFreqs = List<int>.from(defaultFreqs);
    clubSpeeds[8] = 8; // Mode 9
    clubFreqs[8] = 8;

    // Preset 3 (Slot 2): Emerald Respiration
    final breathSpeeds = List<int>.from(defaultSpeeds);
    final breathFreqs = List<int>.from(defaultFreqs);
    breathSpeeds[2] = 4; // Mode 3
    breathFreqs[2] = 8;

    // Preset 4 (Slot 3): Aurora Spectrum
    final rainbowSpeeds = List<int>.from(defaultSpeeds);
    final rainbowFreqs = List<int>.from(defaultFreqs);
    rainbowSpeeds[9] = 5; // Mode 10
    rainbowFreqs[9] = 6;

    // Preset 5 (Slot 4): Police Warning Beacon
    final policeSpeeds = List<int>.from(defaultSpeeds);
    final policeFreqs = List<int>.from(defaultFreqs);
    policeSpeeds[11] = 9; // Mode 12
    policeFreqs[11] = 10;

    return {
      0: PresetData(
        red: 255,
        green: 140,
        blue: 0,
        white: 60,
        brightness: 240,
        mode: 13, // Candle
        modeSpeed: candleSpeeds,
        modeFrequency: candleFreqs,
      ),
      1: PresetData(
        red: 255,
        green: 0,
        blue: 180,
        white: 0,
        brightness: 255,
        mode: 9, // Club
        modeSpeed: clubSpeeds,
        modeFrequency: clubFreqs,
        clubColorMode: 0,
      ),
      2: PresetData(
        red: 0,
        green: 245,
        blue: 160,
        white: 0,
        brightness: 190,
        mode: 3, // Breath
        modeSpeed: breathSpeeds,
        modeFrequency: breathFreqs,
      ),
      3: PresetData(
        red: 0,
        green: 229,
        blue: 255,
        white: 0,
        brightness: 230,
        mode: 10, // Rainbow
        modeSpeed: rainbowSpeeds,
        modeFrequency: rainbowFreqs,
      ),
      4: PresetData(
        red: 255,
        green: 0,
        blue: 68,
        white: 0,
        brightness: 255,
        mode: 12, // Police Strobe
        modeSpeed: policeSpeeds,
        modeFrequency: policeFreqs,
        policeColorMode: 1,
        policeColorAR: 255,
        policeColorAG: 0,
        policeColorAB: 0,
        policeColorBR: 0,
        policeColorBG: 0,
        policeColorBB: 255,
      ),
    };
  }

  static Map<int, String> defaultNames() {
    final Map<int, String> names = {};
    for (int i = 0; i < DeviceCatalog.electrobrightC3RgbwV1.numPresets; i++) {
      names[i] = 'Preset ${i + 1}';
    }
    names[0] = 'Warm Candle';
    names[1] = 'Cyber Club';
    names[2] = 'Emerald Breath';
    names[3] = 'Aurora Spectrum';
    names[4] = 'Police Patrol';
    return names;
  }
}
