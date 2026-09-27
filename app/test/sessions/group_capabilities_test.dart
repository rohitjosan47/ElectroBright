import 'package:electrobright/core/color/colour_engine.dart';
import 'package:electrobright/core/color/hsv.dart';
import 'package:electrobright/core/color/led_white_points.dart';
import 'package:electrobright/core/model/channel_color.dart';
import 'package:electrobright/core/model/channel_layout.dart';
import 'package:electrobright/core/model/light_capabilities.dart';
import 'package:electrobright/core/protocol/eb/eb_fixture_catalog.dart';
import 'package:electrobright/sessions/group_capabilities.dart';
import 'package:flutter_test/flutter_test.dart';

/// The two groups' controls for every mix of their fixture types.
void main() {
  GroupLight light(
    String id,
    ChannelLayout l, {
    LedWhitePoints? wp,
    int modeMask = LightCapabilities.allModes,
  }) => GroupLight(
    id,
    l,
    wp ?? EbFixtureCatalog.forLayout(l).whitePoints,
    LightCapabilities(layout: l, modeMask: modeMask),
  );

  test('every layout belongs to exactly one group', () {
    expect(GroupKind.of(ChannelLayout.rgb), GroupKind.colour);
    expect(GroupKind.of(ChannelLayout.rgbw), GroupKind.colour);
    expect(GroupKind.of(ChannelLayout.rgbcct), GroupKind.colour);
    expect(GroupKind.of(ChannelLayout.cct), GroupKind.white);
    expect(GroupKind.of(ChannelLayout.w), GroupKind.white);
  });

  test('colour group, all 7 mixes of RGB, RGBW and RGBCCT: the wheel reaches '
      'every light and lights no white LED', () {
    const List<ChannelLayout> types = <ChannelLayout>[
      ChannelLayout.rgb,
      ChannelLayout.rgbw,
      ChannelLayout.rgbcct,
    ];
    for (int mask = 1; mask < 8; mask++) {
      final List<GroupLight> lights = <GroupLight>[
        for (int i = 0; i < 3; i++)
          if (mask & (1 << i) != 0) light('l$i', types[i]),
      ];
      final String name = lights.map((GroupLight l) => l.layout.wire).join('+');
      final GroupCapabilities g = GroupCapabilities(GroupKind.colour, lights);
      expect(g.tunableIds, isEmpty, reason: name);
      expect(g.hasTunable || g.hasFixedWhite, isFalse, reason: name);

      final HsvIntent pick = GroupCapabilities.colourPick(
        const HsvIntent(Hsv(30, 0.5, 1), white: 0.8),
      );
      expect(pick, const HsvIntent(Hsv(30, 0.5, 1)), reason: name);
      for (final GroupLight l in lights) {
        final ChannelColor c = ColourEngine(l.whitePoints)
            .encode(pick, l.layout);
        for (int ch = 3; ch < l.layout.n; ch++) {
          expect(c[ch], 0, reason: '$name ${l.layout.wire} channel $ch');
        }
        expect(GroupCapabilities.temperatureFor(3000, l), isNull);
      }
    }
  });

  test('white group, W only: no colour controls, W lights take no '
      'temperature', () {
    final GroupCapabilities g = GroupCapabilities(GroupKind.white, <GroupLight>[
      light('w1', ChannelLayout.w),
      light('w2', ChannelLayout.w, modeMask: 0x1DFF),
    ]);
    expect(g.hasTunable, isFalse);
    expect(g.hasFixedWhite, isTrue);
    expect(g.fixedWhiteIds, <String>['w1', 'w2']);
    for (final GroupLight l in g.lights) {
      expect(GroupCapabilities.temperatureFor(4000, l), isNull);
    }
    // Effects: the union, with the lights each one reaches.
    expect(g.effects, contains(10));
    expect(g.effectIds(10), <String>['w1']);
    expect(g.effectIds(1), <String>['w1', 'w2']);
  });

  test('white group, CCT only and CCT + W: temperature on the CCT lights, '
      'range the union of theirs, each clamped to its own', () {
    final GroupLight narrow = light(
      'cct-narrow',
      ChannelLayout.cct,
      wp: const LedWhitePoints(wwK: 3000, cwK: 5000),
    );
    final GroupLight wide = light(
      'cct-wide',
      ChannelLayout.cct,
      wp: const LedWhitePoints(wwK: 2200, cwK: 6500),
    );
    final GroupLight w = light('w', ChannelLayout.w);
    for (final List<GroupLight> lights in <List<GroupLight>>[
      <GroupLight>[narrow, wide],
      <GroupLight>[narrow, wide, w],
    ]) {
      final GroupCapabilities g = GroupCapabilities(GroupKind.white, lights);
      expect(g.hasTunable, isTrue);
      expect(g.hasFixedWhite, lights.contains(w));
      expect(g.tunableIds, <String>['cct-narrow', 'cct-wide']);
      expect(g.whitePoints.wwK, 2200);
      expect(g.whitePoints.cwK, 6500);
    }
    expect(
      GroupCapabilities.temperatureFor(2500, narrow),
      const WhiteIntent(3000, 1),
    );
    expect(
      GroupCapabilities.temperatureFor(2500, wide),
      const WhiteIntent(2500, 1),
    );
    expect(
      GroupCapabilities.temperatureFor(9000, narrow),
      const WhiteIntent(5000, 1),
    );
    expect(GroupCapabilities.temperatureFor(4000, w), isNull);
  });

  test('value-equal; none has no lights', () {
    List<GroupLight> lights() => <GroupLight>[
      light('a', ChannelLayout.rgb),
      light('b', ChannelLayout.rgbw),
    ];
    expect(
      GroupCapabilities(GroupKind.colour, lights()),
      GroupCapabilities(GroupKind.colour, lights()),
    );
    expect(
      GroupCapabilities(GroupKind.colour, lights()),
      isNot(GroupCapabilities(GroupKind.white, lights())),
    );
    expect(const GroupCapabilities.none(GroupKind.colour).lights, isEmpty);
    expect(const GroupCapabilities.none(GroupKind.white).hasTunable, isFalse);
  });
}
