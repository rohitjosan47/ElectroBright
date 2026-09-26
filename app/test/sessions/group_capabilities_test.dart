import 'package:electrobright/core/color/colour_engine.dart';
import 'package:electrobright/core/color/hsv.dart';
import 'package:electrobright/core/color/led_white_points.dart';
import 'package:electrobright/core/model/channel_layout.dart';
import 'package:electrobright/core/model/light_capabilities.dart';
import 'package:electrobright/core/protocol/eb/eb_fixture_catalog.dart';
import 'package:electrobright/sessions/group_capabilities.dart';
import 'package:flutter_test/flutter_test.dart';

/// The group's colour controls for every mix of fixture types.
void main() {
  const List<ChannelLayout> types = <ChannelLayout>[
    ChannelLayout.rgb,
    ChannelLayout.rgbw,
    ChannelLayout.rgbcct,
    ChannelLayout.cct,
    ChannelLayout.w,
  ];

  GroupLight light(String id, ChannelLayout l, [LedWhitePoints? wp]) =>
      GroupLight(id, l, wp ?? EbFixtureCatalog.forLayout(l).whitePoints);

  /// The table: colour + tunable -> RGB+CCT; colour + RGBW -> RGBW; colour
  /// only -> RGB; tunable only -> CCT; only single whites -> none.
  ColourSurface? expected(Set<ChannelLayout> set) {
    final bool colour = set.any((ChannelLayout l) => l.hasColour);
    final bool tunable = set.any(
      (ChannelLayout l) => l.white == WhiteKind.tunable,
    );
    if (colour && tunable) return ColourSurface.colourPlusTunableWhite;
    if (colour && set.contains(ChannelLayout.rgbw)) {
      return ColourSurface.colourPlusWhite;
    }
    if (colour) return ColourSurface.colour;
    if (tunable) return ColourSurface.tunableWhite;
    return null;
  }

  /// Checks every rule for [lights].
  void check(List<GroupLight> lights, String name) {
    final GroupCapabilities g = GroupCapabilities(lights);
    final Set<ChannelLayout> set = <ChannelLayout>{
      for (final GroupLight l in lights) l.layout,
    };
    List<String> ids(bool Function(GroupLight) test) => <String>[
      for (final GroupLight l in lights)
        if (test(l)) l.id,
    ];
    final ColourSurface? surface = g.surface;
    expect(surface, expected(set), reason: name);
    // The editor's layout shows exactly that surface on a light of its own.
    expect(
      g.surfaceLayout == null
          ? null
          : LightCapabilities.assumed(g.surfaceLayout!).colourSurface,
      surface,
      reason: name,
    );

    // Every control there is reaches at least one light.
    final bool wheel =
        surface == ColourSurface.colour ||
        surface == ColourSurface.colourPlusWhite ||
        surface == ColourSurface.colourPlusTunableWhite;
    final bool whiteLed = surface == ColourSurface.colourPlusWhite;
    final bool temperature =
        surface == ColourSurface.tunableWhite ||
        surface == ColourSurface.colourPlusTunableWhite;
    if (wheel) expect(g.colourAffected, isNotEmpty, reason: name);
    if (whiteLed) expect(g.whiteLedAffected, isNotEmpty, reason: name);
    if (temperature) expect(g.temperatureAffected, isNotEmpty, reason: name);

    // A colour never reaches a CCT or W light; a white never reaches W.
    const HsvIntent red = HsvIntent(Hsv(0, 1, 1), white: 0.5);
    expect(
      g.targets(red),
      ids((GroupLight l) => l.layout.hasColour),
      reason: name,
    );
    for (final double k in <double>[1800, 4000, 9000]) {
      final WhiteIntent white = WhiteIntent(k, 1);
      // Colour lights match it, tunable ones make it; never single whites.
      expect(
        g.targets(white),
        ids((GroupLight l) => l.layout != ChannelLayout.w),
        reason: '$name $k K',
      );
      // Each tunable light clamps to its own LEDs.
      for (final GroupLight l in lights.where((GroupLight l) => l.tunable)) {
        final ColourEngine e = ColourEngine(l.whitePoints);
        final double clamped = k
            .clamp(l.whitePoints.wwK, l.whitePoints.cwK)
            .toDouble();
        expect(
          e.encode(GroupCapabilities.intentFor(white, l)!, l.layout),
          e.encode(WhiteIntent(clamped, 1), l.layout),
          reason: '$name ${l.id} $k K',
        );
      }
    }
    for (final GroupLight l in lights.where((GroupLight l) => l.fixedWhite)) {
      expect(GroupCapabilities.intentFor(red, l), isNull, reason: name);
      expect(
        GroupCapabilities.intentFor(const WhiteIntent(4000, 1), l),
        isNull,
        reason: name,
      );
    }

    // The editor's temperature range is the union of the tunable lights'.
    final List<GroupLight> tunable = lights
        .where((GroupLight l) => l.tunable)
        .toList();
    if (tunable.isNotEmpty) {
      expect(
        g.whitePoints.wwK,
        tunable
            .map((GroupLight l) => l.whitePoints.wwK)
            .reduce((int a, int b) => a < b ? a : b),
        reason: name,
      );
      expect(
        g.whitePoints.cwK,
        tunable
            .map((GroupLight l) => l.whitePoints.cwK)
            .reduce((int a, int b) => a > b ? a : b),
        reason: name,
      );
      expect(
        g.matchKelvins,
        (<int>{
          for (final GroupLight l in lights)
            if (l.fixedWhite) l.whitePoints.wK,
        }.toList()..sort()),
        reason: name,
      );
    } else {
      expect(g.matchKelvins, isEmpty, reason: name);
    }
    expect(g, GroupCapabilities(List<GroupLight>.of(lights)), reason: name);
  }

  test('all 31 mixes of fixture types', () {
    int mixes = 0;
    for (int mask = 1; mask < 1 << types.length; mask++) {
      final List<GroupLight> lights = <GroupLight>[
        for (int i = 0; i < types.length; i++)
          if (mask & 1 << i != 0) light('l$i', types[i]),
      ];
      check(lights, lights.map((GroupLight l) => l.layout.wire).join('+'));
      mixes++;
    }
    expect(mixes, 31);
  });

  test('duplicates: two RGBW, two single whites, one tunable white', () {
    const LedWhitePoints tunable = LedWhitePoints(wwK: 2700, cwK: 6500);
    final List<GroupLight> lights = <GroupLight>[
      light('rgbw-1', ChannelLayout.rgbw),
      light('rgbw-2', ChannelLayout.rgbw),
      light('w-warm', ChannelLayout.w, const LedWhitePoints(wK: 3000)),
      light('w-neutral', ChannelLayout.w, const LedWhitePoints(wK: 4000)),
      light('cct', ChannelLayout.cct, tunable),
    ];
    check(lights, 'duplicates');
    final GroupCapabilities g = GroupCapabilities(lights);
    expect(g.surface, ColourSurface.colourPlusTunableWhite);
    expect(g.surfaceLayout, ChannelLayout.rgbcct);
    expect(g.colourIds, <String>['rgbw-1', 'rgbw-2']);
    expect(g.rgbwIds, <String>['rgbw-1', 'rgbw-2']);
    expect(g.tunableIds, <String>['cct']);
    expect(g.fixedWhiteIds, <String>['w-warm', 'w-neutral']);
    expect(g.temperatureAffected, <String>['rgbw-1', 'rgbw-2', 'cct']);
    expect(g.matchKelvins, <int>[3000, 4000]);
    expect(g.limitedCount(2000), 1);
    expect(g.limitedCount(4000), 0);
    expect(g.limitedCount(9000), 1);
  });

  test('only single whites: no colour controls', () {
    final GroupCapabilities g = GroupCapabilities(<GroupLight>[
      light('a', ChannelLayout.w),
      light('b', ChannelLayout.w),
    ]);
    expect(g.surface, isNull);
    expect(g.surfaceLayout, isNull);
    expect(g.matchKelvins, isEmpty);
    expect(const GroupCapabilities.none().surface, isNull);
  });
}
