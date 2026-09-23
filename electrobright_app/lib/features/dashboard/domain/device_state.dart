import 'package:flutter/material.dart';
import '../../presets/domain/preset_data.dart';
import '../../../core/devices/device_profile.dart';

/// Immutable model representing the complete state of the ElectroBright LED fixture.
class LiveColorState {
  final int red, green, blue, white, brightness;
  const LiveColorState({
    required this.red,
    required this.green,
    required this.blue,
    required this.white,
    required this.brightness,
  });
}

class DeviceState {
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
  final bool isSleeping;
  final bool soundEnabled;
  // Timer state is reported by the firmware in STATUS (active flag and
  // remaining seconds); the app counts down locally between STATUS replies.
  final bool timerActive;
  final int timerSecondsSet;
  final int? timerRemainingSec;
  final String? firmwareVersion;
  final Set<int> savedPresets;
  final Map<int, String> presetNames;
  final Map<int, PresetData> presetSnapshots;
  final int? activePresetId;
  final String? lastError;
  final int writeErrorCount;

  final bool supportsBinaryFastPath;

  const DeviceState({
    required this.red,
    required this.green,
    required this.blue,
    required this.white,
    required this.brightness,
    required this.mode,
    required this.modeSpeed,
    required this.modeFrequency,
    required this.fireworkColorMode,
    required this.clubColorMode,
    required this.policeColorMode,
    required this.policeColorAR,
    required this.policeColorAG,
    required this.policeColorAB,
    required this.policeColorAW,
    required this.policeColorBR,
    required this.policeColorBG,
    required this.policeColorBB,
    required this.policeColorBW,
    required this.isSleeping,
    required this.soundEnabled,
    required this.timerActive,
    required this.timerSecondsSet,
    this.timerRemainingSec,
    this.firmwareVersion,
    required this.savedPresets,
    required this.presetNames,
    required this.presetSnapshots,
    this.activePresetId,
    this.lastError,
    required this.writeErrorCount,
    required this.supportsBinaryFastPath,
  });

  factory DeviceState.initial(DeviceProfile profile) {
    return DeviceState(
      red: 255,
      green: 255,
      blue: 255,
      white: 0,
      brightness: 255,
      mode: 1,
      modeSpeed: List.filled(profile.numModes, 5),
      modeFrequency: List.filled(profile.numModes, 5),
      fireworkColorMode: 0,
      clubColorMode: 0,
      policeColorMode: 1,
      policeColorAR: 255,
      policeColorAG: 165,
      policeColorAB: 0,
      policeColorAW: 0,
      policeColorBR: 0,
      policeColorBG: 0,
      policeColorBB: 0,
      policeColorBW: 255,
      isSleeping: false,
      soundEnabled: true,
      timerActive: false,
      timerSecondsSet: 0,
      timerRemainingSec: null,
      firmwareVersion: null,
      // No demo presets: the hardware's PRESET_LIST is the source of truth
      // for which slots are occupied (a fresh install / factory reset is empty).
      savedPresets: const {},
      presetNames: const {},
      presetSnapshots: const {},
      activePresetId: null,
      lastError: null,
      writeErrorCount: 0,
      supportsBinaryFastPath: false,
    );
  }

  Color get activeRgbColor => Color.fromARGB(255, red, green, blue);
  Color get policeColorA => Color.fromARGB(255, policeColorAR, policeColorAG, policeColorAB);
  Color get policeColorB => Color.fromARGB(255, policeColorBR, policeColorBG, policeColorBB);

  String getPresetName(int slotId) => presetNames[slotId] ?? 'Preset ${slotId + 1}';

  int get currentSpeed {
    if (mode >= 1 && mode <= modeSpeed.length) {
      return modeSpeed[mode - 1];
    }
    return 5;
  }

  int get currentFrequency {
    if (mode >= 1 && mode <= modeFrequency.length) {
      return modeFrequency[mode - 1];
    }
    return 5;
  }

  DeviceState copyWith({
    int? red,
    int? green,
    int? blue,
    int? white,
    int? brightness,
    int? mode,
    List<int>? modeSpeed,
    List<int>? modeFrequency,
    int? fireworkColorMode,
    int? clubColorMode,
    int? policeColorMode,
    int? policeColorAR,
    int? policeColorAG,
    int? policeColorAB,
    int? policeColorAW,
    int? policeColorBR,
    int? policeColorBG,
    int? policeColorBB,
    int? policeColorBW,
    bool? isSleeping,
    bool? soundEnabled,
    bool? timerActive,
    int? timerSecondsSet,
    int? timerRemainingSec,
    String? firmwareVersion,
    Set<int>? savedPresets,
    Map<int, String>? presetNames,
    Map<int, PresetData>? presetSnapshots,
    int? activePresetId,
    bool clearActivePreset = false,
    String? lastError,
    bool clearLastError = false,
    int? writeErrorCount,
    bool? supportsBinaryFastPath,
  }) {
    return DeviceState(
      red: red ?? this.red,
      green: green ?? this.green,
      blue: blue ?? this.blue,
      white: white ?? this.white,
      brightness: brightness ?? this.brightness,
      mode: mode ?? this.mode,
      modeSpeed: modeSpeed ?? List.from(this.modeSpeed),
      modeFrequency: modeFrequency ?? List.from(this.modeFrequency),
      fireworkColorMode: fireworkColorMode ?? this.fireworkColorMode,
      clubColorMode: clubColorMode ?? this.clubColorMode,
      policeColorMode: policeColorMode ?? this.policeColorMode,
      policeColorAR: policeColorAR ?? this.policeColorAR,
      policeColorAG: policeColorAG ?? this.policeColorAG,
      policeColorAB: policeColorAB ?? this.policeColorAB,
      policeColorAW: policeColorAW ?? this.policeColorAW,
      policeColorBR: policeColorBR ?? this.policeColorBR,
      policeColorBG: policeColorBG ?? this.policeColorBG,
      policeColorBB: policeColorBB ?? this.policeColorBB,
      policeColorBW: policeColorBW ?? this.policeColorBW,
      isSleeping: isSleeping ?? this.isSleeping,
      soundEnabled: soundEnabled ?? this.soundEnabled,
      timerActive: timerActive ?? this.timerActive,
      timerSecondsSet: timerSecondsSet ?? this.timerSecondsSet,
      timerRemainingSec: timerRemainingSec ?? this.timerRemainingSec,
      firmwareVersion: firmwareVersion ?? this.firmwareVersion,
      savedPresets: savedPresets ?? Set.from(this.savedPresets),
      presetNames: presetNames ?? Map.from(this.presetNames),
      presetSnapshots: presetSnapshots ?? Map.from(this.presetSnapshots),
      activePresetId: clearActivePreset ? null : (activePresetId ?? this.activePresetId),
      lastError: clearLastError ? null : (lastError ?? this.lastError),
      writeErrorCount: writeErrorCount ?? this.writeErrorCount,
      supportsBinaryFastPath: supportsBinaryFastPath ?? this.supportsBinaryFastPath,
    );
  }
}
