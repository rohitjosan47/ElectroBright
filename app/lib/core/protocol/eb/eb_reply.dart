import 'package:meta/meta.dart';

import '../../model/rgbw.dart';
import 'eb_constants.dart';
import 'eb_scene.dart';

/// One reply line from the firmware, parsed strictly
/// (firmware/core/ElectroBrightCore/src/protocol/Replies.cpp). Anything that is not
/// exactly well-formed becomes [EbMalformed] and must never be applied.
@immutable
sealed class EbReply {
  const EbReply();
}

final class EbOk extends EbReply {
  const EbOk();
  @override
  String toString() => 'OK';
}

final class EbError extends EbReply {
  const EbError(this.code, {this.presetId});

  final String code;

  /// Set for `ERROR:PRESET_EMPTY:<id>`.
  final int? presetId;

  static const String storage = 'STORAGE';
  static const String presetEmpty = 'PRESET_EMPTY';
  static const String presetIdInvalid = 'PRESET_ID';
  static const String unknownCommand = 'UNKNOWN_CMD';
  static const String format = 'FORMAT';
  static const String modeInvalid = 'MODE_INVALID';

  @override
  String toString() =>
      presetId == null ? 'ERROR:$code' : 'ERROR:$code:$presetId';
}

final class EbInfo extends EbReply {
  const EbInfo(this.model);
  final String model;
  @override
  String toString() => 'INFO:$model';
}

final class EbVersion extends EbReply {
  const EbVersion(this.version, this.major, this.minor, this.patch);
  final String version;
  final int major;
  final int minor;
  final int patch;
  @override
  String toString() => 'VERSION:$version';
}

final class EbCaps extends EbReply {
  const EbCaps(this.fields);
  final Map<String, String> fields;
  int? get protocol => int.tryParse(fields['PROTOCOL'] ?? '');
  @override
  String toString() => 'CAPS:$fields';
}

final class EbStatusReply extends EbReply {
  const EbStatusReply(this.status);
  final EbStatus status;
  @override
  String toString() => 'STATUS:$status';
}

@immutable
final class EbLevels {
  const EbLevels(this.speed, this.frequency);
  final int speed;
  final int frequency;
  @override
  bool operator ==(Object other) =>
      other is EbLevels && other.speed == speed && other.frequency == frequency;
  @override
  int get hashCode => Object.hash(speed, frequency);
}

final class EbModeSettings extends EbReply {
  const EbModeSettings(this.levels);

  /// One pair per mode, mode 1 first. Its length is the device's mode count.
  final List<EbLevels> levels;
  @override
  String toString() => 'MODE_SETTINGS(${levels.length})';
}

final class EbPresets extends EbReply {
  const EbPresets(this.slots);
  final Set<int> slots;
  @override
  String toString() => 'PRESETS:$slots';
}

final class EbCapabilities extends EbReply {
  const EbCapabilities({
    required this.speed,
    required this.frequency,
    required this.colorMode,
  });
  final bool speed;
  final bool frequency;
  final bool colorMode;
  @override
  String toString() => 'CAPABILITIES:$speed/$frequency/$colorMode';
}

final class EbDiag extends EbReply {
  const EbDiag(this.values);
  final Map<String, int> values;
  @override
  String toString() => 'DIAG:$values';
}

final class EbMalformed extends EbReply {
  const EbMalformed(this.line, this.reason);
  final String line;
  final String reason;
  @override
  String toString() => 'MALFORMED($reason): $line';
}

final RegExp _code = RegExp(r'^[A-Z][A-Z0-9_]*$');
final RegExp _uint = RegExp(r'^\d{1,10}$');
final RegExp _version = RegExp(
  r'^(\d+)\.(\d+)\.(\d+)(?:[-+.][0-9A-Za-z.\-]+)?$',
);
final RegExp _capsKey = RegExp(r'^[A-Z][A-Z0-9_]*$');

int? _uintIn(String s, int lo, int hi) {
  if (!_uint.hasMatch(s)) return null;
  final int v = int.parse(s);
  return v >= lo && v <= hi ? v : null;
}

/// Parses one reply line (without its terminator).
EbReply parseEbReply(String line) {
  if (line == 'OK') return const EbOk();
  final int colon = line.indexOf(':');
  if (colon <= 0) return EbMalformed(line, 'no prefix');
  final String head = line.substring(0, colon);
  final String body = line.substring(colon + 1);
  return switch (head) {
    'ERROR' => _error(line, body),
    'INFO' => body.isNotEmpty ? EbInfo(body) : EbMalformed(line, 'empty model'),
    'VERSION' => _versionReply(line, body),
    'CAPS' => _caps(line, body),
    'STATUS' => _status(line, body),
    'MODE_SETTINGS' => _modeSettings(line, body),
    'PRESETS' => _presets(line, body),
    'CAPABILITIES' => _capabilities(line, body),
    'DIAG' => _diag(line, body),
    _ => EbMalformed(line, 'unknown prefix'),
  };
}

EbReply _error(String line, String body) {
  if (body.startsWith('${EbError.presetEmpty}:')) {
    final int? id = _uintIn(
      body.substring(EbError.presetEmpty.length + 1),
      0,
      31,
    );
    return id == null
        ? EbMalformed(line, 'preset id')
        : EbError(EbError.presetEmpty, presetId: id);
  }
  return _code.hasMatch(body) ? EbError(body) : EbMalformed(line, 'code');
}

EbReply _versionReply(String line, String body) {
  final RegExpMatch? m = _version.firstMatch(body);
  if (m == null) return EbMalformed(line, 'version');
  return EbVersion(
    body,
    int.parse(m.group(1)!),
    int.parse(m.group(2)!),
    int.parse(m.group(3)!),
  );
}

EbReply _caps(String line, String body) {
  final Map<String, String> fields = <String, String>{};
  for (final String part in body.split(',')) {
    final int eq = part.indexOf('=');
    if (eq <= 0 || eq == part.length - 1) {
      return EbMalformed(line, 'caps field');
    }
    final String key = part.substring(0, eq);
    if (!_capsKey.hasMatch(key)) return EbMalformed(line, 'caps key');
    fields[key] = part.substring(eq + 1);
  }
  return EbCaps(Map<String, String>.unmodifiable(fields));
}

EbReply _status(String line, String body) {
  final List<String> f = body.split(',');
  if (f.length != Eb.statusFields) return EbMalformed(line, 'field count');
  final List<int> v = <int>[];
  const List<(int, int)> ranges = <(int, int)>[
    (0, 255), (0, 255), (0, 255), (0, 255), // colour
    (0, 255), // brightness
    (1, Eb.numModes),
    (Eb.minLevel, Eb.maxLevel), (Eb.minLevel, Eb.maxLevel),
    (0, 1), (0, 1), (0, 1), // colour modes
    (0, 1), (0, 1), // sleeping, timerActive
    (0, Eb.timerMaxSeconds),
    (0, 1), // sound
    (0, 255), (0, 255), (0, 255), (0, 255), // police A
    (0, 255), (0, 255), (0, 255), (0, 255), // police B
  ];
  for (int i = 0; i < f.length; i++) {
    final int? x = _uintIn(f[i], ranges[i].$1, ranges[i].$2);
    if (x == null) return EbMalformed(line, 'field $i');
    v.add(x);
  }
  return EbStatusReply(
    EbStatus(
      color: Rgbw(v[0], v[1], v[2], v[3]),
      brightness: v[4],
      mode: v[5],
      speed: v[6],
      frequency: v[7],
      fireworkColorMode: v[8],
      clubColorMode: v[9],
      policeColorMode: v[10],
      sleeping: v[11] == 1,
      timerActive: v[12] == 1,
      timerRemainingSec: v[13],
      soundOn: v[14] == 1,
      policeA: Rgbw(v[15], v[16], v[17], v[18]),
      policeB: Rgbw(v[19], v[20], v[21], v[22]),
    ),
  );
}

EbReply _modeSettings(String line, String body) {
  final List<String> pairs = body.split(';');
  if (pairs.isEmpty || pairs.length > 32) {
    return EbMalformed(line, 'pair count');
  }
  final List<EbLevels> levels = <EbLevels>[];
  for (final String p in pairs) {
    final List<String> sf = p.split(',');
    if (sf.length != 2) return EbMalformed(line, 'pair');
    final int? s = _uintIn(sf[0], Eb.minLevel, Eb.maxLevel);
    final int? fq = _uintIn(sf[1], Eb.minLevel, Eb.maxLevel);
    if (s == null || fq == null) return EbMalformed(line, 'level');
    levels.add(EbLevels(s, fq));
  }
  return EbModeSettings(List<EbLevels>.unmodifiable(levels));
}

EbReply _presets(String line, String body) {
  if (body.isEmpty) return const EbPresets(<int>{});
  if (!body.endsWith(',')) return EbMalformed(line, 'trailing comma');
  final Set<int> slots = <int>{};
  for (final String s in body.substring(0, body.length - 1).split(',')) {
    final int? id = _uintIn(s, 0, 31);
    if (id == null || !slots.add(id)) return EbMalformed(line, 'slot');
  }
  return EbPresets(Set<int>.unmodifiable(slots));
}

EbReply _capabilities(String line, String body) {
  if (body == 'NONE') {
    return const EbCapabilities(
      speed: false,
      frequency: false,
      colorMode: false,
    );
  }
  final List<String> t = body.split(',');
  const Set<String> known = <String>{'SPEED', 'FREQUENCY', 'COLOR_MODE'};
  if (t.any((String x) => !known.contains(x)) || t.toSet().length != t.length) {
    return EbMalformed(line, 'capability');
  }
  return EbCapabilities(
    speed: t.contains('SPEED'),
    frequency: t.contains('FREQUENCY'),
    colorMode: t.contains('COLOR_MODE'),
  );
}

EbReply _diag(String line, String body) {
  final Map<String, int> values = <String, int>{};
  for (final String part in body.split(',')) {
    final int eq = part.indexOf('=');
    if (eq <= 0) return EbMalformed(line, 'diag field');
    final String value = part.substring(eq + 1);
    if (!_uint.hasMatch(value)) return EbMalformed(line, 'diag value');
    values[part.substring(0, eq)] = int.parse(value);
  }
  return EbDiag(Map<String, int>.unmodifiable(values));
}
