import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

import '../../model/rgbw.dart';
import 'eb_constants.dart';

const ListEquality<int> _listEq = ListEquality<int>();

/// Which colour-mode flag a mode uses (firmware state::colorModeFor).
enum EbColorModeKind {
  firework(4, 'FIREWORK_COLOR_MODE'),
  club(9, 'CLUB_COLOR_MODE'),
  police(12, 'POLICE_COLOR_MODE');

  const EbColorModeKind(this.mode, this.command);
  final int mode;
  final String command;

  static EbColorModeKind? forMode(int mode) =>
      values.firstWhereOrNull((EbColorModeKind k) => k.mode == mode);
}

enum EbPoliceSlot {
  a('POLICE_COLOR_A'),
  b('POLICE_COLOR_B');

  const EbPoliceSlot(this.command);
  final String command;
}

/// Everything a preset captures (firmware Scene): the light's look, including
/// every mode's slider pair. Colour modes: 0 = picked colour / custom A-B,
/// 1 = auto palette / red-blue.
@immutable
final class EbScene {
  EbScene({
    required this.color,
    required this.brightness,
    required this.mode,
    required List<int> speeds,
    required List<int> frequencies,
    required this.fireworkColorMode,
    required this.clubColorMode,
    required this.policeColorMode,
    required this.policeA,
    required this.policeB,
  }) : speeds = List<int>.unmodifiable(speeds),
       frequencies = List<int>.unmodifiable(frequencies);

  /// Firmware defaults (state::defaultScene).
  factory EbScene.defaults() => EbScene(
    color: const Rgbw(255, 255, 255, 0),
    brightness: 255,
    mode: 1,
    speeds: List<int>.filled(Eb.numModes, 5),
    frequencies: List<int>.filled(Eb.numModes, 5),
    fireworkColorMode: 0,
    clubColorMode: 0,
    policeColorMode: 1,
    policeA: const Rgbw(255, 165, 0, 0),
    policeB: const Rgbw(0, 0, 0, 255),
  );

  final Rgbw color;
  final int brightness;
  final int mode;
  final List<int> speeds;
  final List<int> frequencies;
  final int fireworkColorMode;
  final int clubColorMode;
  final int policeColorMode;
  final Rgbw policeA;
  final Rgbw policeB;

  int get speed => speeds[mode - 1];
  int get frequency => frequencies[mode - 1];

  int colorMode(EbColorModeKind kind) => switch (kind) {
    EbColorModeKind.firework => fireworkColorMode,
    EbColorModeKind.club => clubColorMode,
    EbColorModeKind.police => policeColorMode,
  };

  Rgbw police(EbPoliceSlot slot) => slot == EbPoliceSlot.a ? policeA : policeB;

  EbScene copyWith({
    Rgbw? color,
    int? brightness,
    int? mode,
    List<int>? speeds,
    List<int>? frequencies,
    int? fireworkColorMode,
    int? clubColorMode,
    int? policeColorMode,
    Rgbw? policeA,
    Rgbw? policeB,
  }) => EbScene(
    color: color ?? this.color,
    brightness: brightness ?? this.brightness,
    mode: mode ?? this.mode,
    speeds: speeds ?? this.speeds,
    frequencies: frequencies ?? this.frequencies,
    fireworkColorMode: fireworkColorMode ?? this.fireworkColorMode,
    clubColorMode: clubColorMode ?? this.clubColorMode,
    policeColorMode: policeColorMode ?? this.policeColorMode,
    policeA: policeA ?? this.policeA,
    policeB: policeB ?? this.policeB,
  );

  EbScene withSpeed(int mode, int value) =>
      copyWith(speeds: List<int>.of(speeds)..[mode - 1] = value);

  EbScene withFrequency(int mode, int value) =>
      copyWith(frequencies: List<int>.of(frequencies)..[mode - 1] = value);

  EbScene withColorMode(EbColorModeKind kind, int value) => switch (kind) {
    EbColorModeKind.firework => copyWith(fireworkColorMode: value),
    EbColorModeKind.club => copyWith(clubColorMode: value),
    EbColorModeKind.police => copyWith(policeColorMode: value),
  };

  EbScene withPolice(EbPoliceSlot slot, Rgbw c) =>
      slot == EbPoliceSlot.a ? copyWith(policeA: c) : copyWith(policeB: c);

  Map<String, Object> toJson() => <String, Object>{
    'color': color.toList(),
    'brightness': brightness,
    'mode': mode,
    'speeds': speeds,
    'frequencies': frequencies,
    'fireworkColorMode': fireworkColorMode,
    'clubColorMode': clubColorMode,
    'policeColorMode': policeColorMode,
    'policeA': policeA.toList(),
    'policeB': policeB.toList(),
  };

  /// Strict: returns null when anything is missing or out of range.
  static EbScene? fromJson(Object? json) {
    if (json is! Map<String, Object?>) return null;
    Rgbw? rgbw(Object? v) {
      if (v is! List<Object?> ||
          v.length != 4 ||
          v.any((Object? e) => e is! int)) {
        return null;
      }
      final Rgbw c = Rgbw(
        v[0]! as int,
        v[1]! as int,
        v[2]! as int,
        v[3]! as int,
      );
      return c.isValid ? c : null;
    }

    List<int>? levels(Object? v) {
      if (v is! List<Object?> || v.length != Eb.numModes) return null;
      final List<int> out = <int>[];
      for (final Object? e in v) {
        if (e is! int || e < Eb.minLevel || e > Eb.maxLevel) return null;
        out.add(e);
      }
      return out;
    }

    int? inRange(Object? v, int lo, int hi) =>
        v is int && v >= lo && v <= hi ? v : null;

    final Rgbw? color = rgbw(json['color']);
    final int? brightness = inRange(json['brightness'], 0, 255);
    final int? mode = inRange(json['mode'], 1, Eb.numModes);
    final List<int>? speeds = levels(json['speeds']);
    final List<int>? frequencies = levels(json['frequencies']);
    final int? fw = inRange(json['fireworkColorMode'], 0, 1);
    final int? club = inRange(json['clubColorMode'], 0, 1);
    final int? police = inRange(json['policeColorMode'], 0, 1);
    final Rgbw? a = rgbw(json['policeA']);
    final Rgbw? b = rgbw(json['policeB']);
    if (color == null ||
        brightness == null ||
        mode == null ||
        speeds == null ||
        frequencies == null ||
        fw == null ||
        club == null ||
        police == null ||
        a == null ||
        b == null) {
      return null;
    }
    return EbScene(
      color: color,
      brightness: brightness,
      mode: mode,
      speeds: speeds,
      frequencies: frequencies,
      fireworkColorMode: fw,
      clubColorMode: club,
      policeColorMode: police,
      policeA: a,
      policeB: b,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is EbScene &&
      other.color == color &&
      other.brightness == brightness &&
      other.mode == mode &&
      _listEq.equals(other.speeds, speeds) &&
      _listEq.equals(other.frequencies, frequencies) &&
      other.fireworkColorMode == fireworkColorMode &&
      other.clubColorMode == clubColorMode &&
      other.policeColorMode == policeColorMode &&
      other.policeA == policeA &&
      other.policeB == policeB;

  @override
  int get hashCode => Object.hash(
    color,
    brightness,
    mode,
    _listEq.hash(speeds),
    _listEq.hash(frequencies),
    fireworkColorMode,
    clubColorMode,
    policeColorMode,
    policeA,
    policeB,
  );

  @override
  String toString() =>
      'EbScene($color br=$brightness mode=$mode s=$speeds f=$frequencies '
      'cm=$fireworkColorMode/$clubColorMode/$policeColorMode A=$policeA B=$policeB)';
}

/// One STATUS line: the live scene as far as STATUS reports it (only the
/// current mode's slider pair) plus the device-owned state.
@immutable
final class EbStatus {
  const EbStatus({
    required this.color,
    required this.brightness,
    required this.mode,
    required this.speed,
    required this.frequency,
    required this.fireworkColorMode,
    required this.clubColorMode,
    required this.policeColorMode,
    required this.sleeping,
    required this.timerActive,
    required this.timerRemainingSec,
    required this.soundOn,
    required this.policeA,
    required this.policeB,
  });

  final Rgbw color;
  final int brightness;
  final int mode;
  final int speed;
  final int frequency;
  final int fireworkColorMode;
  final int clubColorMode;
  final int policeColorMode;
  final bool sleeping;
  final bool timerActive;
  final int timerRemainingSec;
  final bool soundOn;
  final Rgbw policeA;
  final Rgbw policeB;

  /// [base] with every field STATUS carries (other modes' pairs unchanged).
  EbScene applyTo(EbScene base) => base
      .copyWith(
        color: color,
        brightness: brightness,
        mode: mode,
        fireworkColorMode: fireworkColorMode,
        clubColorMode: clubColorMode,
        policeColorMode: policeColorMode,
        policeA: policeA,
        policeB: policeB,
      )
      .withSpeed(mode, speed)
      .withFrequency(mode, frequency);

  @override
  bool operator ==(Object other) =>
      other is EbStatus &&
      other.color == color &&
      other.brightness == brightness &&
      other.mode == mode &&
      other.speed == speed &&
      other.frequency == frequency &&
      other.fireworkColorMode == fireworkColorMode &&
      other.clubColorMode == clubColorMode &&
      other.policeColorMode == policeColorMode &&
      other.sleeping == sleeping &&
      other.timerActive == timerActive &&
      other.timerRemainingSec == timerRemainingSec &&
      other.soundOn == soundOn &&
      other.policeA == policeA &&
      other.policeB == policeB;

  @override
  int get hashCode => Object.hash(
    color,
    brightness,
    mode,
    speed,
    frequency,
    fireworkColorMode,
    clubColorMode,
    policeColorMode,
    sleeping,
    timerActive,
    timerRemainingSec,
    soundOn,
    policeA,
    policeB,
  );

  @override
  String toString() =>
      'EbStatus($color br=$brightness mode=$mode s=$speed f=$frequency '
      'sleep=$sleeping timer=$timerActive/$timerRemainingSec sound=$soundOn)';
}
