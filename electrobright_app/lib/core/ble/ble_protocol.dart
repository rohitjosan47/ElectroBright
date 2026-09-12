/// Parsed status payload from the ESP32-C3 firmware.
class ParsedStatus {
  final int red;
  final int green;
  final int blue;
  final int white;
  final int brightness;
  final int mode;
  final int currentModeSpeed;
  final int currentModeFrequency;
  final int fireworkColorMode;
  final int clubColorMode;
  final int policeColorMode;
  final bool? sleeping;
  final bool? timerActive;
  final int? timerRemainingSec;
  final bool? soundEnabled;

  const ParsedStatus({
    required this.red,
    required this.green,
    required this.blue,
    required this.white,
    required this.brightness,
    required this.mode,
    required this.currentModeSpeed,
    required this.currentModeFrequency,
    required this.fireworkColorMode,
    required this.clubColorMode,
    required this.policeColorMode,
    this.sleeping,
    this.timerActive,
    this.timerRemainingSec,
    this.soundEnabled,
  });
}

/// Zero-crash parser and serializer for the ElectroBright BLE protocol.
class BleProtocol {
  /// Parses raw notification strings received from the ESP32 TX characteristic.
  static ParsedStatus? parseStatus(String raw) {
    final trimmed = raw.trim();
    if (!trimmed.startsWith('STATUS:')) return null;

    final data = trimmed.substring(7);
    final parts = data.split(',');
    if (parts.length < 11) return null;

    try {
      return ParsedStatus(
        red: int.parse(parts[0]),
        green: int.parse(parts[1]),
        blue: int.parse(parts[2]),
        white: int.parse(parts[3]),
        brightness: int.parse(parts[4]),
        mode: int.parse(parts[5]),
        currentModeSpeed: int.parse(parts[6]),
        currentModeFrequency: int.parse(parts[7]),
        fireworkColorMode: int.parse(parts[8]),
        clubColorMode: int.parse(parts[9]),
        policeColorMode: int.parse(parts[10]),
        sleeping: parts.length >= 12 ? parts[11] == '1' : null,
        timerActive: parts.length >= 13 ? parts[12] == '1' : null,
        timerRemainingSec: parts.length >= 14 ? int.tryParse(parts[13]) : null,
        soundEnabled: parts.length >= 15 ? parts[14] == '1' : null,
      );
    } catch (_) {
      return null;
    }
  }

  /// Parses `MODE_SETTINGS:s1,f1;s2,f2;...` for all 13 modes.
  /// Returns a map of modeId (1-13) -> { 'speed': s, 'frequency': f }.
  static Map<int, Map<String, int>>? parseModeSettings(String raw) {
    final trimmed = raw.trim();
    if (!trimmed.startsWith('MODE_SETTINGS:')) return null;

    final data = trimmed.substring(14);
    final pairs = data.split(';');
    final Map<int, Map<String, int>> result = {};

    for (int i = 0; i < pairs.length; i++) {
      final pair = pairs[i].split(',');
      if (pair.length == 2) {
        final speed = int.tryParse(pair[0]);
        final freq = int.tryParse(pair[1]);
        if (speed != null && freq != null) {
          result[i + 1] = {'speed': speed, 'frequency': freq};
        }
      }
    }
    return result;
  }

  /// Parses `PRESETS:0,2,5,` into a Set of occupied preset indices.
  static Set<int>? parsePresets(String raw) {
    final trimmed = raw.trim();
    if (!trimmed.startsWith('PRESETS:')) return null;

    final data = trimmed.substring(8);
    final Set<int> result = {};
    for (final item in data.split(',')) {
      final clean = item.trim();
      if (clean.isNotEmpty) {
        final idx = int.tryParse(clean);
        if (idx != null) result.add(idx);
      }
    }
    return result;
  }

  /// Parses `INFO:<value>` replies. Returns null on anything malformed.
  static String? parseInfoValue(String raw) {
    final trimmed = raw.trim();
    if (!trimmed.startsWith('INFO:')) return null;
    final value = trimmed.substring(5).trim();
    return value.isEmpty ? null : value;
  }

  /// Parses `ERROR:<CODE>` replies. Returns the error code or null.
  static String? parseError(String raw) {
    final trimmed = raw.trim();
    if (!trimmed.startsWith('ERROR:')) return null;
    return trimmed.substring(6).trim();
  }

  /// Parses `VERSION:<x.y.z>` replies. Returns the version string or null.
  static String? parseVersion(String raw) {
    final trimmed = raw.trim();
    if (!trimmed.startsWith('VERSION:')) return null;
    return trimmed.substring(8).trim();
  }

  // --- Command Generators ---
  static String setRgbw(int r, int g, int b, int w) => 'RGBW:$r,$g,$b,$w\n';
  static String setBrightness(int br) => 'BRIGHTNESS:$br\n';
  static String setMode(int mode) => 'MODE:$mode\n';
  static String setSpeed(int speed) => 'SPEED:$speed\n';
  static String setFrequency(int freq) => 'FREQUENCY:$freq\n';
  static String setFireworkColorMode(int mode) => 'FIREWORK_COLOR_MODE:$mode\n';
  static String setClubColorMode(int mode) => 'CLUB_COLOR_MODE:$mode\n';
  static String setPoliceColorMode(int mode) => 'POLICE_COLOR_MODE:$mode\n';
  static String setPoliceColorA(int r, int g, int b, int w) => 'POLICE_COLOR_A:$r,$g,$b,$w\n';
  static String setPoliceColorB(int r, int g, int b, int w) => 'POLICE_COLOR_B:$r,$g,$b,$w\n';
  static String savePreset(int id) => 'PRESET_SAVE:$id\n';
  static String loadPreset(int id) => 'PRESET_LOAD:$id\n';
  static String deletePreset(int id) => 'PRESET_DELETE:$id\n';
  static String requestPresetList() => 'PRESET_LIST\n';
  static String requestStatus() => 'STATUS\n';
  static String requestModeSettings() => 'MODE_SETTINGS\n';
  static String sleep() => 'SLEEP\n';
  static String wake() => 'WAKE\n';
  static String soundOn() => 'SOUND_ON\n';
  static String soundOff() => 'SOUND_OFF\n';
  static String setTimer(int minutes) => 'TIMER:$minutes\n';
  static String factoryReset() => 'FACTORY_RESET\n';
  static String ping() => 'PING\n';
  static String getInfo() => 'INFO\n';
  static String getVersion() => 'VERSION\n';

  /// Generates a 6-byte binary fast-path packet for continuous color streaming.
  /// Format: [0xAA, R, G, B, W, Checksum]
  /// Checksum = (R ^ G ^ B ^ W ^ 0x55) & 0xFF
  static List<int> encodeRgbwBinary(int r, int g, int b, int w) {
    final cleanR = r.clamp(0, 255);
    final cleanG = g.clamp(0, 255);
    final cleanB = b.clamp(0, 255);
    final cleanW = w.clamp(0, 255);
    final checksum = (cleanR ^ cleanG ^ cleanB ^ cleanW ^ 0x55) & 0xFF;
    return <int>[0xAA, cleanR, cleanG, cleanB, cleanW, checksum];
  }

  /// Evaluates whether the firmware version is >= 2.8.0 to support binary streaming.
  static bool isBinaryFastPathSupported(String? versionString) {
    if (versionString == null) return false;
    final clean = versionString.trim();
    final parts = clean.split('.');
    if (parts.isEmpty) return false;
    final major = int.tryParse(parts[0]);
    if (major == null) return false;
    if (major > 2) return true;
    if (major < 2) return false;
    final minor = parts.length > 1 ? int.tryParse(parts[1]) : 0;
    if (minor == null) return false;
    return minor >= 8;
  }
}
