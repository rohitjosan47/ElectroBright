import 'dart:math' as math;

import 'package:meta/meta.dart';

import '../model/channel_color.dart';
import '../model/channel_layout.dart';
import 'color_science.dart';
import 'hsv.dart';
import 'led_white_points.dart';

/// What the user asked for, independent of the light's channels.
@immutable
sealed class ColourIntent {
  const ColourIntent();
}

/// A colour from the wheel; [white] is the dedicated W LED level (RGBW).
final class HsvIntent extends ColourIntent {
  const HsvIntent(this.hsv, {this.white = 0});
  final Hsv hsv;
  final double white;
  @override
  bool operator ==(Object other) =>
      other is HsvIntent && other.hsv == hsv && other.white == white;
  @override
  int get hashCode => Object.hash(hsv, white);
  @override
  String toString() => 'HsvIntent($hsv, white $white)';
}

/// White at a colour temperature; [level] is perceptual 0..1.
final class WhiteIntent extends ColourIntent {
  const WhiteIntent(this.kelvin, this.level);
  final double kelvin;
  final double level;
  @override
  bool operator ==(Object other) =>
      other is WhiteIntent && other.kelvin == kelvin && other.level == level;
  @override
  int get hashCode => Object.hash(kelvin, level);
  @override
  String toString() =>
      'WhiteIntent(${kelvin.round()} K, ${(level * 100).round()} %)';
}

/// Exact channel values (the Channels disclosure, presets, mixed looks).
final class RawIntent extends ColourIntent {
  const RawIntent(this.color);
  final ChannelColor color;
  @override
  bool operator ==(Object other) => other is RawIntent && other.color == color;
  @override
  int get hashCode => color.hashCode;
  @override
  String toString() => 'RawIntent($color)';
}

/// Turns what the user asks for into the channel values of a light's layout
/// and back. Pure: everything a colour screen needs, testable without Flutter.
///
/// Channel values are perceptual (the firmware applies gamma 2.2), so all
/// mixing happens in linear light and is encoded with
/// [ColorScience.linearToLevel].
final class ColourEngine {
  const ColourEngine([this.whitePoints = const LedWhitePoints()]);

  final LedWhitePoints whitePoints;

  /// Temperatures the light can make as white: between its two white LEDs
  /// (CCT, RGBCCT), anything from RGB (RGB, RGBW), its own LED (W).
  ({double min, double max}) whiteRange(ChannelLayout layout) =>
      switch (layout.white) {
        WhiteKind.tunable => (
          min: whitePoints.wwK.toDouble(),
          max: whitePoints.cwK.toDouble(),
        ),
        WhiteKind.single when !layout.hasColour => (
          min: whitePoints.wK.toDouble(),
          max: whitePoints.wK.toDouble(),
        ),
        _ => (min: 1900, max: 10000),
      };

  // ---------------------------------------------------------------- encode

  ChannelColor encode(ColourIntent intent, ChannelLayout layout) =>
      switch (intent) {
        RawIntent(:final ChannelColor color) =>
          color.layout == layout
              ? color
              : throw ArgumentError(
                  'raw ${color.layout.wire} for ${layout.wire}',
                ),
        HsvIntent(:final Hsv hsv, :final double white) => _encodeHsv(
          hsv,
          white,
          layout,
        ),
        WhiteIntent(:final double kelvin, :final double level) => _encodeWhite(
          kelvin,
          level,
          layout,
        ),
      };

  ChannelColor _encodeHsv(Hsv hsv, double white, ChannelLayout layout) {
    final List<int> rgb = hsv.toRgb8();
    switch (layout) {
      case ChannelLayout.rgb:
        return ChannelColor(layout, rgb);
      case ChannelLayout.rgbw:
        return ChannelColor(layout, <int>[...rgb, _byte(white)]);
      case ChannelLayout.rgbcct:
        return ChannelColor(layout, <int>[...rgb, 0, 0]);
      case ChannelLayout.cct:
        // The nearest white: its temperature, at the colour's value.
        final LinearRgb lin = LinearRgb(
          ColorScience.levelToLinear(rgb[0]),
          ColorScience.levelToLinear(rgb[1]),
          ColorScience.levelToLinear(rgb[2]),
        );
        final double k = lin.max <= 0
            ? 4000
            : ColorScience.estimateKelvin(lin.normalized());
        return _encodeWhite(k, hsv.v, layout);
      case ChannelLayout.w:
        return ChannelColor(layout, <int>[_byte(hsv.v)]);
    }
  }

  ChannelColor _encodeWhite(double kelvin, double level, ChannelLayout layout) {
    final double lin = ColorScience.levelToLinear(_byte(level));
    switch (layout) {
      case ChannelLayout.w:
        return ChannelColor(layout, <int>[_byte(level)]);
      case ChannelLayout.cct:
      case ChannelLayout.rgbcct:
        final (double cw, double ww) = _mix(kelvin);
        final List<int> whites = <int>[
          ColorScience.linearToLevel(cw * lin),
          ColorScience.linearToLevel(ww * lin),
        ];
        return ChannelColor(
          layout,
          layout == ChannelLayout.cct ? whites : <int>[0, 0, 0, ...whites],
        );
      case ChannelLayout.rgb:
        final LinearRgb t = ColorScience.kelvinToLinear(kelvin);
        return ChannelColor(layout, <int>[
          ColorScience.linearToLevel(t.r * lin),
          ColorScience.linearToLevel(t.g * lin),
          ColorScience.linearToLevel(t.b * lin),
        ]);
      case ChannelLayout.rgbw:
        // As much as possible from the W LED, the rest from RGB.
        final LinearRgb t = ColorScience.kelvinToLinear(kelvin);
        final LinearRgb w = ColorScience.kelvinToLinear(
          whitePoints.wK.toDouble(),
        );
        double wl = double.infinity;
        for (final (double tc, double wc) in <(double, double)>[
          (t.r, w.r),
          (t.g, w.g),
          (t.b, w.b),
        ]) {
          if (wc > 1e-6) wl = math.min(wl, tc / wc);
        }
        wl = wl.isFinite ? wl.clamp(0.0, 1.0) : 0;
        final LinearRgb rest = LinearRgb(
          math.max(0, t.r - wl * w.r),
          math.max(0, t.g - wl * w.g),
          math.max(0, t.b - wl * w.b),
        );
        final double peak = math.max(rest.max, wl);
        final double k = peak <= 0 ? 0 : lin / peak;
        return ChannelColor(layout, <int>[
          ColorScience.linearToLevel(rest.r * k),
          ColorScience.linearToLevel(rest.g * k),
          ColorScience.linearToLevel(rest.b * k),
          ColorScience.linearToLevel(wl * k),
        ]);
    }
  }

  /// Cool/warm LED mix (linear, larger one = 1) for [kelvin], interpolated in
  /// mireds between the two LEDs and clamped to their range.
  (double, double) _mix(double kelvin) {
    final double mCw = 1e6 / whitePoints.cwK;
    final double mWw = 1e6 / whitePoints.wwK;
    final double t = ((1e6 / kelvin - mCw) / (mWw - mCw)).clamp(0.0, 1.0);
    final double cw = 1 - t, ww = t;
    final double peak = math.max(cw, ww);
    return (cw / peak, ww / peak);
  }

  static int _byte(double unit) => (unit.clamp(0.0, 1.0) * 255).round();

  /// The channel levels (perceptual 0..1, the largest 1) of [intent] at full
  /// intensity, unquantised: the colour the user asked for, exactly, where
  /// the 8-bit channels of a dim colour cannot resolve its hue. Null for raw
  /// channel values (they are all there is).
  List<double>? fullLevels(ColourIntent intent, ChannelLayout layout) {
    List<double> unit(List<double> l) {
      final double m = l.fold(0, math.max);
      return m <= 0 ? l : <double>[for (final double x in l) x / m];
    }

    List<double> bytes(ChannelColor c) => <double>[
      for (final int v in c.values) v / 255,
    ];
    switch (intent) {
      case RawIntent():
        return null;
      case WhiteIntent(:final double kelvin):
        // Proportions do not depend on the level: at full level the 8-bit
        // rounding is a fraction of a percent.
        return unit(bytes(_encodeWhite(kelvin, 1, layout)));
      case HsvIntent(:final Hsv hsv, :final double white):
        // Black keeps its hue: shown as the colour at full value.
        final List<double> rgb = hsv.v > 0 || white > 0
            ? hsv.toRgb()
            : hsv.copyWith(v: 1).toRgb();
        switch (layout) {
          case ChannelLayout.rgb:
            return unit(rgb);
          case ChannelLayout.rgbw:
            return unit(<double>[...rgb, white.clamp(0.0, 1.0)]);
          case ChannelLayout.rgbcct:
            return unit(<double>[...rgb, 0, 0]);
          case ChannelLayout.cct:
            final LinearRgb lin = LinearRgb(
              math.pow(rgb[0], 2.2).toDouble(),
              math.pow(rgb[1], 2.2).toDouble(),
              math.pow(rgb[2], 2.2).toDouble(),
            );
            final double k = lin.max <= 0
                ? 4000
                : ColorScience.estimateKelvin(lin.normalized());
            return unit(bytes(_encodeWhite(k, 1, layout)));
          case ChannelLayout.w:
            return const <double>[1];
        }
    }
  }

  // ---------------------------------------------------------------- decode

  /// The intent a colour most likely came from. [hint] (the intent the
  /// editor last used) keeps the hue at grey and the temperature at black.
  ColourIntent decode(ChannelColor c, {ColourIntent? hint}) {
    final ChannelLayout l = c.layout;
    switch (l) {
      case ChannelLayout.w:
        return WhiteIntent(whitePoints.wK.toDouble(), c[0] / 255);
      case ChannelLayout.cct:
        return _decodeWhites(c[0], c[1], hint);
      case ChannelLayout.rgbcct:
        final bool colour = c[0] > 0 || c[1] > 0 || c[2] > 0;
        final bool whites = c[3] > 0 || c[4] > 0;
        if (colour && whites) return RawIntent(c);
        if (!colour) return _decodeWhites(c[3], c[4], hint);
        return HsvIntent(_hsvOf(c, hint));
      case ChannelLayout.rgb:
        return HsvIntent(_hsvOf(c, hint));
      case ChannelLayout.rgbw:
        return HsvIntent(_hsvOf(c, hint), white: c[3] / 255);
    }
  }

  Hsv _hsvOf(ChannelColor c, ColourIntent? hint) => Hsv.fromRgb8(
    c[0],
    c[1],
    c[2],
    previous: hint is HsvIntent ? hint.hsv : null,
  );

  WhiteIntent _decodeWhites(int cwByte, int wwByte, ColourIntent? hint) {
    final double cw = ColorScience.levelToLinear(cwByte);
    final double ww = ColorScience.levelToLinear(wwByte);
    final double total = math.max(cw, ww);
    if (total <= 0) {
      return WhiteIntent(hint is WhiteIntent ? hint.kelvin : 4000, 0);
    }
    final double t = ww / (cw + ww);
    final double mCw = 1e6 / whitePoints.cwK;
    final double mWw = 1e6 / whitePoints.wwK;
    final double kelvin = 1e6 / (mCw + t * (mWw - mCw));
    return WhiteIntent(kelvin, math.pow(total, 1 / 2.2).toDouble());
  }

  // ---------------------------------------------------------------- previews

  /// Effective output of a light as a fraction of full scale (perceptual):
  /// channel [level] 0..255 scaled by master [brightness] 0..255, exactly as
  /// the firmware multiplies them in linear light.
  static double output(int level, int brightness) =>
      level * brightness / (255 * 255);
}
