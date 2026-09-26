import 'package:flutter/material.dart';

import '../../core/color/color_science.dart';
import '../../core/color/led_white_points.dart';
import '../../core/color/light_tone.dart';
import '../../core/model/channel_color.dart';
import '../../core/model/channel_layout.dart';
import '../../l10n/app_localizations.dart';
import '../tokens/tokens.dart';
import '../tone/tone_scope.dart';

/// Short type name shown on badges ("RGB + CCT").
String fixtureTypeName(AppLocalizations l, ChannelLayout layout) =>
    switch (layout) {
      ChannelLayout.rgbw => l.typeRgbw,
      ChannelLayout.rgb => l.typeRgb,
      ChannelLayout.rgbcct => l.typeRgbcct,
      ChannelLayout.cct => l.typeCct,
      ChannelLayout.w => l.typeW,
    };

/// What the type means ("Colour + tunable white").
String fixtureTypeDescription(AppLocalizations l, ChannelLayout layout) =>
    switch (layout) {
      ChannelLayout.rgbw => l.typeRgbwLong,
      ChannelLayout.rgb => l.typeRgbLong,
      ChannelLayout.rgbcct => l.typeRgbcctLong,
      ChannelLayout.cct => l.typeCctLong,
      ChannelLayout.w => l.typeWLong,
    };

String channelName(AppLocalizations l, ChannelRole role) => switch (role) {
  ChannelRole.r => l.channelR,
  ChannelRole.g => l.channelG,
  ChannelRole.b => l.channelB,
  ChannelRole.w => l.channelW,
  ChannelRole.cw => l.channelCw,
  ChannelRole.ww => l.channelWw,
};

/// Screen colour of one LED at full output.
Color ledColor(ChannelRole role, LedWhitePoints wp) =>
    Color(ColorScience.toArgb(LayoutPreview.ledColour(role, wp).normalized()));

/// One dot per LED of the light, in wire order; with [color], each dot is lit
/// by its channel's level.
class ChannelDots extends StatelessWidget {
  const ChannelDots({
    required this.layout,
    this.color,
    this.whitePoints = const LedWhitePoints(),
    this.size = 8,
    super.key,
  });

  final ChannelLayout layout;
  final ChannelColor? color;
  final LedWhitePoints whitePoints;
  final double size;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l = AppLocalizations.of(context);
    final bool dark = ToneScope.darkOf(context);
    return Semantics(
      label: layout.roles.map((ChannelRole r) => channelName(l, r)).join(', '),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (int i = 0; i < layout.n; i++)
            Padding(
              padding: EdgeInsets.only(right: i + 1 < layout.n ? size / 2 : 0),
              child: _Dot(
                color: ledColor(layout.roles[i], whitePoints),
                level: color == null ? 1 : color![i] / 255,
                size: size,
                dark: dark,
              ),
            ),
        ],
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({
    required this.color,
    required this.level,
    required this.size,
    required this.dark,
  });
  final Color color;
  final double level;
  final double size;
  final bool dark;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: Color.lerp(
        dark ? const Color(0xFF2A2D35) : const Color(0xFFD9DCE3),
        color,
        0.25 + 0.75 * level,
      ),
      border: Border.all(
        color: (dark ? Colors.white : Colors.black).withValues(alpha: 0.14),
        width: 0.5,
      ),
    ),
  );
}

/// Capsule naming a light's type, with its LEDs as dots.
class FixtureTypeBadge extends StatelessWidget {
  const FixtureTypeBadge({
    required this.layout,
    this.whitePoints = const LedWhitePoints(),
    super.key,
  });

  final ChannelLayout layout;
  final LedWhitePoints whitePoints;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l = AppLocalizations.of(context);
    final bool dark = ToneScope.darkOf(context);
    final Color fg = dark ? Colors.white : const Color(0xFF15171C);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Space.xs, vertical: 3),
      decoration: ShapeDecoration(
        shape: const StadiumBorder(),
        color: fg.withValues(alpha: 0.08),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          ChannelDots(layout: layout, whitePoints: whitePoints, size: 6),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              fixtureTypeName(l, layout),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: fg.withValues(alpha: 0.75),
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.2,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
