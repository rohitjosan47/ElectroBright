import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

import '../core/color/colour_engine.dart';
import '../core/color/led_white_points.dart';
import '../core/model/channel_layout.dart';
import '../core/model/light_capabilities.dart';

/// The two automatic groups; every light is in exactly one.
enum GroupKind {
  /// Lights with colour LEDs (RGB, RGBW, RGBCCT).
  colour,

  /// White-only lights (CCT, W).
  white;

  static GroupKind of(ChannelLayout layout) =>
      layout.hasColour ? colour : white;
}

/// One light of a group, as far as the group's controls go.
@immutable
final class GroupLight {
  const GroupLight(this.id, this.layout, this.whitePoints, this.capabilities);
  final String id;
  final ChannelLayout layout;
  final LedWhitePoints whitePoints;

  /// Learned from its firmware, else assumed (the fixture's).
  final LightCapabilities capabilities;

  bool get hasColour => layout.hasColour;
  bool get tunable => layout == ChannelLayout.cct;

  /// A single white LED and nothing else (W).
  bool get fixedWhite => layout == ChannelLayout.w;

  @override
  bool operator ==(Object other) =>
      other is GroupLight &&
      other.id == id &&
      other.layout == layout &&
      other.whitePoints == whitePoints &&
      other.capabilities == capabilities;
  @override
  int get hashCode => Object.hash(id, layout, whitePoints, capabilities);
  @override
  String toString() => 'GroupLight($id, ${layout.wire})';
}

/// What a group's controls are, from the lights it drives (their types,
/// never which are connected, so the controls don't reshuffle), and which
/// lights each control reaches. The colour group picks colours only (every
/// white LED off, so all its lights match); the white group sets a colour
/// temperature on its tunable lights, and its single whites take brightness,
/// power, effects and the timer only.
@immutable
final class GroupCapabilities {
  GroupCapabilities(this.kind, Iterable<GroupLight> lights)
    : lights = List<GroupLight>.unmodifiable(lights);

  /// No lights: no controls.
  const GroupCapabilities.none(this.kind) : lights = const <GroupLight>[];

  final GroupKind kind;

  /// In Home's order.
  final List<GroupLight> lights;

  List<String> _ids(bool Function(GroupLight l) test) => <String>[
    for (final GroupLight l in lights)
      if (test(l)) l.id,
  ];

  /// Lights a colour temperature reaches (the white group's CCT lights).
  List<String> get tunableIds =>
      kind == GroupKind.white ? _ids((GroupLight l) => l.tunable) : const [];

  /// Single-white lights (W): power, brightness, effects and timer only.
  List<String> get fixedWhiteIds => _ids((GroupLight l) => l.fixedWhite);

  bool get hasTunable => tunableIds.isNotEmpty;
  bool get hasFixedWhite => fixedWhiteIds.isNotEmpty;

  /// The group's white points: the temperature range is the union of the
  /// CCT lights' ranges; the single white is the first W light's.
  LedWhitePoints get whitePoints {
    const LedWhitePoints d = LedWhitePoints();
    if (kind != GroupKind.white) return d;
    final List<GroupLight> tunable = <GroupLight>[
      for (final GroupLight l in lights)
        if (l.tunable) l,
    ];
    final GroupLight? fixed = lights
        .where((GroupLight l) => l.fixedWhite)
        .firstOrNull;
    return LedWhitePoints(
      wK: fixed?.whitePoints.wK ?? d.wK,
      wwK: tunable.isEmpty
          ? d.wwK
          : tunable.map((GroupLight l) => l.whitePoints.wwK).min,
      cwK: tunable.isEmpty
          ? d.cwK
          : tunable.map((GroupLight l) => l.whitePoints.cwK).max,
    );
  }

  /// Every effect some light has, in the catalog's order.
  List<int> get effects =>
      <int>{for (final GroupLight l in lights) ...l.capabilities.modes}.toList()
        ..sort();

  /// The lights [mode] reaches.
  List<String> effectIds(int mode) =>
      _ids((GroupLight l) => l.capabilities.supportsMode(mode));

  /// The colour group's pick as every light takes it: no white LED lit.
  static HsvIntent colourPick(HsvIntent pick) =>
      pick.white == 0 ? pick : HsvIntent(pick.hsv);

  /// [kelvin] as [light] takes it (clamped to its range, full level), or
  /// null when it has no tunable white.
  static WhiteIntent? temperatureFor(double kelvin, GroupLight light) =>
      light.tunable
      ? WhiteIntent(
          kelvin.clamp(light.whitePoints.wwK, light.whitePoints.cwK).toDouble(),
          1.0,
        )
      : null;

  @override
  bool operator ==(Object other) =>
      other is GroupCapabilities &&
      other.kind == kind &&
      const ListEquality<GroupLight>().equals(other.lights, lights);
  @override
  int get hashCode => Object.hash(kind, Object.hashAll(lights));
}
