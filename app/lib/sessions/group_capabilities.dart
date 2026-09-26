import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

import '../core/color/colour_engine.dart';
import '../core/color/led_white_points.dart';
import '../core/model/channel_layout.dart';
import '../core/model/light_capabilities.dart';

/// One light the group drives, as far as its colour controls go.
@immutable
final class GroupLight {
  const GroupLight(this.id, this.layout, this.whitePoints);
  final String id;
  final ChannelLayout layout;
  final LedWhitePoints whitePoints;

  bool get hasColour => layout.hasColour;
  bool get tunable => layout.white == WhiteKind.tunable;
  bool get rgbw => layout == ChannelLayout.rgbw;

  /// A single white LED and nothing else (W).
  bool get fixedWhite => !layout.hasColour && layout.white == WhiteKind.single;

  @override
  bool operator ==(Object other) =>
      other is GroupLight &&
      other.id == id &&
      other.layout == layout &&
      other.whitePoints == whitePoints;
  @override
  int get hashCode => Object.hash(id, layout, whitePoints);
  @override
  String toString() => 'GroupLight($id, ${layout.wire})';
}

/// What the group's colour controls are, from the lights it drives (their
/// types, never which are connected, so the controls don't reshuffle), and
/// which lights each control reaches. A single-light screen gets its
/// controls from [LightCapabilities.colourSurface]; the group follows the
/// same model over the union of its lights.
@immutable
final class GroupCapabilities {
  GroupCapabilities(Iterable<GroupLight> lights)
    : lights = List<GroupLight>.unmodifiable(lights);

  /// No lights: no colour controls.
  const GroupCapabilities.none() : lights = const <GroupLight>[];

  /// In Home's order.
  final List<GroupLight> lights;

  List<String> _ids(bool Function(GroupLight l) test) => <String>[
    for (final GroupLight l in lights)
      if (test(l)) l.id,
  ];

  /// Lights with colour LEDs (RGB, RGBW, RGBCCT).
  List<String> get colourIds => _ids((GroupLight l) => l.hasColour);

  /// Lights with tunable white (CCT, RGBCCT).
  List<String> get tunableIds => _ids((GroupLight l) => l.tunable);

  /// Lights with a white LED beside their colour (RGBW).
  List<String> get rgbwIds => _ids((GroupLight l) => l.rgbw);

  /// Single-white lights (W): power, brightness and effects only.
  List<String> get fixedWhiteIds => _ids((GroupLight l) => l.fixedWhite);

  /// The group's colour controls; null when no light has any (only W).
  ColourSurface? get surface {
    final bool colour = lights.any((GroupLight l) => l.hasColour);
    final bool tunable = lights.any((GroupLight l) => l.tunable);
    final bool rgbw = lights.any((GroupLight l) => l.rgbw);
    if (colour && tunable) return ColourSurface.colourPlusTunableWhite;
    if (colour && rgbw) return ColourSurface.colourPlusWhite;
    if (colour) return ColourSurface.colour;
    if (tunable) return ColourSurface.tunableWhite;
    return null;
  }

  /// The layout whose own controls are [surface] (the colour editor's
  /// value layout).
  ChannelLayout? get surfaceLayout => switch (surface) {
    ColourSurface.colourPlusTunableWhite => ChannelLayout.rgbcct,
    ColourSurface.colourPlusWhite => ChannelLayout.rgbw,
    ColourSurface.colour => ChannelLayout.rgb,
    ColourSurface.tunableWhite => ChannelLayout.cct,
    ColourSurface.intensity || null => null,
  };

  /// For the colour editor: the temperature range is the union of the
  /// tunable lights' ranges; the white LED is the first RGBW light's.
  LedWhitePoints get whitePoints {
    final List<GroupLight> tunable = lights
        .where((GroupLight l) => l.tunable)
        .toList();
    final GroupLight? rgbw = lights.where((GroupLight l) => l.rgbw).firstOrNull;
    const LedWhitePoints d = LedWhitePoints();
    return LedWhitePoints(
      wK: rgbw?.whitePoints.wK ?? d.wK,
      wwK: tunable.isEmpty
          ? d.wwK
          : tunable.map((GroupLight l) => l.whitePoints.wwK).min,
      cwK: tunable.isEmpty
          ? d.cwK
          : tunable.map((GroupLight l) => l.whitePoints.cwK).max,
    );
  }

  /// Temperatures to offer as "match the white lights": the single-white
  /// lights' own, when there are tunable lights to match them.
  List<int> get matchKelvins => lights.any((GroupLight l) => l.tunable)
      ? (<int>{
          for (final GroupLight l in lights)
            if (l.fixedWhite) l.whitePoints.wK,
        }.toList()..sort())
      : const <int>[];

  /// Lights the colour wheel reaches.
  List<String> get colourAffected => colourIds;

  /// Lights the white-LED slider reaches.
  List<String> get whiteLedAffected => rgbwIds;

  /// Lights a colour temperature reaches: tunable lights make it with their
  /// white LEDs, colour lights match it with their colour.
  List<String> get temperatureAffected =>
      _ids((GroupLight l) => l.tunable || l.hasColour);

  /// Tunable lights that cannot reach [kelvin] (they stop at their end).
  int limitedCount(double kelvin) => lights
      .where(
        (GroupLight l) =>
            l.tunable &&
            (kelvin < l.whitePoints.wwK || kelvin > l.whitePoints.cwK),
      )
      .length;

  /// [intent] as [light] takes it, or null when it doesn't apply to it:
  /// colours go to colour lights only, whites to tunable and colour lights;
  /// exact channels of another layout go as what they look like.
  static ColourIntent? intentFor(ColourIntent intent, GroupLight light) =>
      switch (intent) {
        RawIntent(:final color) when color.layout == light.layout => intent,
        RawIntent(:final color) => switch (const ColourEngine().decode(color)) {
          RawIntent() => null,
          final ColourIntent decoded => intentFor(decoded, light),
        },
        HsvIntent() => light.hasColour ? intent : null,
        WhiteIntent() => light.hasColour || light.tunable ? intent : null,
      };

  /// The lights [intent] reaches.
  List<String> targets(ColourIntent intent) =>
      _ids((GroupLight l) => intentFor(intent, l) != null);

  @override
  bool operator ==(Object other) =>
      other is GroupCapabilities &&
      const ListEquality<GroupLight>().equals(other.lights, lights);
  @override
  int get hashCode => Object.hashAll(lights);
}
