import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/color/light_surfaces.dart';
import '../../../design/controls/glass_slider.dart';
import '../../../design/glass/glass_surface.dart';
import '../../../design/tokens/tokens.dart';
import '../../../design/tone/tone_scope.dart';
import '../../../l10n/app_localizations.dart';

/// The brightness pill: one fixed fill per theme ([PillFill]), a sun that
/// follows the level and the level as text. [mixed]: the lights it drives
/// differ; it says so until a drag sets them all to one value.
class BrightnessPillSlider extends StatelessWidget {
  const BrightnessPillSlider({
    required this.value,
    required this.enabled,
    required this.fg,
    required this.onChangeStart,
    required this.onChanged,
    required this.onChangeEnd,
    this.mixed = false,
    this.intensity = false,
    super.key,
  });

  /// 0..1 (0 while off or asleep).
  final double value;
  final bool mixed;

  /// A single-white light: the pill is its intensity.
  final bool intensity;
  final bool enabled;
  final Color fg;
  final VoidCallback onChangeStart;

  /// Every move of the finger (live).
  final ValueChanged<double> onChanged;

  /// The release.
  final ValueChanged<double> onChangeEnd;

  /// What the pill says: "Off" at 0 (released there, or asleep), otherwise
  /// the percentage, never "0 %" while the light still gives some light.
  static String label(AppLocalizations l, double x) =>
      x <= 0 ? l.brightnessOff : '${math.max(1, (x * 100).round())} %';

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l = AppLocalizations.of(context);
    final bool dark = ToneScope.darkOf(context);
    String text(double x) => mixed ? l.mixed : label(l, x);
    // Light: the fill is the light's colour (LightSurfaces.pillTintOf), with
    // whichever ink reads on it. Dark: the original clear fill and its ink.
    final Color onFill = dark
        ? PillFill.inkOf(dark: true)
        : Color(LightSurfaces.pillTintOf(ToneScope.of(context)).ink);
    // Dimmed, but on light surfaces never below 4.5:1.
    final double dimFloor = dark ? 0 : LightSurfaces.dimAlpha;
    return GlassSlider(
      key: const ValueKey<String>('brightness'),
      value: value,
      semanticLabel: intensity ? l.intensity : l.brightness,
      enabled: enabled,
      height: 56,
      // Light: real liquid glass over the canvas (dark keeps the panel).
      glassTier: dark ? GlassTier.panel : GlassTier.chrome,
      valueText: text,
      // The sun follows the level: small and faint low, full at the top.
      leadingBuilder: (double x, double width) {
        final bool overFill = x * width >= Space.m + 24;
        return SizedBox.square(
          dimension: 24,
          child: Center(
            child: Icon(
              Icons.wb_sunny_outlined,
              key: const ValueKey<String>('brightness-icon'),
              size: 15 + 6 * x,
              color: (overFill ? onFill : fg).withValues(
                alpha: math.max(dimFloor, x <= 0 ? 0.4 : 0.55 + 0.45 * x),
              ),
            ),
          ),
        );
      },
      trailingBuilder: (double x, double width) {
        final bool overFill = x * width >= width - Space.m - 20;
        return Text(
          text(x),
          style: TextStyle(
            color: (overFill ? onFill : fg).withValues(
              alpha: x <= 0 ? math.max(dimFloor, 0.6) : 1,
            ),
            fontWeight: FontWeight.w500,
            fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
          ),
        );
      },
      onChangeStart: (_) => onChangeStart(),
      onChanged: onChanged,
      onChangeEnd: onChangeEnd,
    );
  }
}
