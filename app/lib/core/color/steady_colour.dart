import 'dart:math' as math;

import 'package:meta/meta.dart';

import '../model/channel_color.dart';
import '../model/channel_layout.dart';
import 'color_science.dart';
import 'led_white_points.dart';
import 'light_tone.dart';

/// A light's colour at full intensity as the UI shows it, as channel levels
/// (perceptual 0..1, the largest 1), kept steady where 8-bit channels cannot
/// resolve it.
///
/// Brightness is shown by lengths and levels, never by the colour, so the
/// colour is the channel vector scaled up to full. Which colour that is
/// follows where it came from (the caller decides, from the session's colour
/// origin), never how close two values are:
/// * the user's pick on this phone ([next]'s `intent`): exactly that colour,
///   at any level;
/// * channels the user set exactly ([next]'s `exact`, the Channels sliders):
///   exactly those channels;
/// * channels of any other origin (the light, a preset, another client):
///   kept steady where 8 bits cannot resolve the hue (3,1,0 vs 3,2,0): the
///   shown levels are kept while the channels are what they would quantise
///   to (within [tolerance] steps), and re-read when they are not;
/// * except for a pick, below [holdBelow] of full scale the last colour is
///   held.
@immutable
final class SteadyLevels {
  const SteadyLevels(this.source, this.levels);

  /// The channels these levels show.
  final ChannelColor source;

  /// One level per channel of [source]'s layout, the largest 1.
  final List<double> levels;

  ChannelLayout get layout => source.layout;

  /// All channels below this fraction of full scale: the hue is held.
  static const double holdBelow = 0.02;

  /// Channel steps the shown levels may differ from the channels by (one:
  /// covers rounding and truncating encoders alike).
  static const double tolerance = 1;

  /// The levels to show for [channels], after [previous]. [intent]: the
  /// user's pick at full intensity (ColourEngine.fullLevels) that set
  /// [channels]; [exact]: [channels] were set by the user as they are.
  static SteadyLevels? next(
    SteadyLevels? previous,
    ChannelColor? channels, {
    List<double>? intent,
    bool exact = false,
  }) {
    if (channels == null) return previous;
    final SteadyLevels? prev = previous?.layout == channels.layout
        ? previous
        : null;
    if (intent != null && intent.length == channels.layout.n) {
      return SteadyLevels(channels, List<double>.unmodifiable(intent));
    }
    final int top = channels.maxChannel;
    if (prev != null) {
      final bool dim = top < holdBelow * 255;
      if (dim || !exact && prev._quantisesTo(channels)) {
        return prev.source == channels
            ? prev
            : SteadyLevels(channels, prev.levels);
      }
    }
    if (top <= 0) return null;
    return SteadyLevels(
      channels,
      List<double>.unmodifiable(<double>[
        for (final int v in channels.values) v / top,
      ]),
    );
  }

  /// Whether these levels, scaled to [c]'s largest channel, come out as [c].
  bool _quantisesTo(ChannelColor c) {
    final int top = c.maxChannel;
    for (int i = 0; i < c.layout.n; i++) {
      if ((levels[i] * top - c[i]).abs() > tolerance + 1e-9) return false;
    }
    return true;
  }

  /// The light these levels make (linear, the largest channel 1).
  LinearRgb emitted(LedWhitePoints wp) {
    LinearRgb sum = const LinearRgb(0, 0, 0);
    for (int i = 0; i < layout.n; i++) {
      if (levels[i] <= 0) continue;
      sum =
          sum +
          LayoutPreview.ledColour(layout.roles[i], wp) *
              math.pow(levels[i], 2.2).toDouble();
    }
    return sum.max <= 0 ? sum : sum.normalized();
  }

  /// These levels' colour when they show [c], else null (the caller derives
  /// it from [c] itself).
  static LinearRgb? colourOf(
    SteadyLevels? steady,
    ChannelColor c,
    LedWhitePoints wp,
  ) => steady != null && steady.source == c ? steady.emitted(wp) : null;

  @override
  bool operator ==(Object other) =>
      other is SteadyLevels &&
      other.source == source &&
      _sameLevels(other.levels, levels);

  static bool _sameLevels(List<double> a, List<double> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(source, Object.hashAll(levels));

  @override
  String toString() =>
      'SteadyLevels($source, ${levels.map((double l) => l.toStringAsFixed(3)).join(',')})';
}
